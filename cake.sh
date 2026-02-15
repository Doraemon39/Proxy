#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: Bash >= 4.0 is required (current: $BASH_VERSION)" >&2
  exit 1
fi

CFG="/etc/default/qos-cake"
if [[ -r "$CFG" ]]; then
  # shellcheck source=/etc/default/qos-cake
  source "$CFG"
fi

# ===== 默认值 =====
UP_BW="${UP_BW:-20mbit}"                # 必填：空则给默认
MODE="${MODE-"triple-isolate"}"         # 允许空值（用 - 而不是 :-）
DIFFSERV="${DIFFSERV-"diffserv4"}"      # 允许 DIFFSERV="" 来禁用
NAT="${NAT:-no}"
ACK_FILTER="${ACK_FILTER:-yes}"
RTT="${RTT-}"                           # 允许空
DOWN_BW="${DOWN_BW-}"                   # 允许空（默认关闭下行整形）
IFB_DEV="${IFB_DEV:-ifb0}"
EXTRA_CAKE_OPTS="${EXTRA_CAKE_OPTS-}"
DISABLE_OFFLOAD="${DISABLE_OFFLOAD:-yes}"  # yes/no；默认关闭 WAN 口 tso/gso/gro
DELETE_IFB_ON_STOP="${DELETE_IFB_ON_STOP:-no}"  # yes/no；yes 时 stop 会删除 IFB 设备
ALLOW_IFB_REUSE="${ALLOW_IFB_REUSE:-no}"        # yes/no；yes 时允许覆盖非本脚本标记的 IFB root qdisc
ALLOW_UNOWNED_WAN_CAKE_DELETE="${ALLOW_UNOWNED_WAN_CAKE_DELETE:-no}"  # yes/no；yes 时允许删除无 ownership marker 的 WAN root cake
INGRESS_PREF="${INGRESS_PREF:-49152}"           # 用固定 pref 标记本脚本创建的 ingress filter
OFFLOAD_STATE_DIR="${OFFLOAD_STATE_DIR:-/run/qos-cake}"  # offload 状态文件目录

CMD="${1:-}"
WAN_IF="${WAN_IF-}"
if [[ -n "${2:-}" ]]; then
  WAN_IF="$2"
fi

warn_virt_limits() {
  # LXC/OpenVZ 常见限制：无法 modprobe / 无法创建 IFB
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt="$(systemd-detect-virt -c 2>/dev/null || true)"
    case "$virt" in
      lxc|openvz|container)
        echo "WARN: Detected container virtualization ($virt). modprobe/IFB may be restricted; ingress shaping may fail." >&2
        ;;
    esac
  fi
}

detect_wan_if() {
  # IPv4 优先，命中即返回；失败再尝试 IPv6
  local dev=""

  dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -n "$dev" ]]; then
    echo "$dev"
    return 0
  fi

  dev="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  [[ -n "$dev" ]] && echo "$dev"
}

nat_flag_auto() {
  # 检测系统是否有 NAT（MASQUERADE/masquerade）规则：nftables 或 iptables
  if command -v nft >/dev/null 2>&1; then
    if nft list ruleset 2>/dev/null | grep -qiE '\bmasquerade\b'; then
      echo "nat"
      return 0
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    if iptables -t nat -S 2>/dev/null | grep -qiE '\bMASQUERADE\b'; then
      echo "nat"
      return 0
    fi
  fi

  echo ""
}

require_if_exists_or_exit() {
  local dev="$1"
  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "ERROR: Interface '$dev' does not exist." >&2
    exit 1
  fi
}

require_cmd_or_exit() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' not found in PATH." >&2
    exit 1
  fi
}

is_ifb_device() {
  local dev="$1"

  ip -o link show type ifb 2>/dev/null | \
    awk -F': ' '{name=$2; sub(/@.*/, "", name); print name}' | \
    grep -Fxq "$dev"
}

ifb_created_state_file() {
  local dev="$1"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"

  echo "$OFFLOAD_STATE_DIR/ifb-created-${safe}.state"
}

save_ifb_created_state() {
  local ifb="$1"
  local state_file=""
  local tmp_file=""

  state_file="$(ifb_created_state_file "$ifb")"
  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; IFB ownership marker is unavailable." >&2
    return 1
  fi

  tmp_file="${state_file}.tmp.$$"
  if printf '%s\n' "$ifb" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to save IFB ownership marker to '$state_file'." >&2
  return 1
}

ifb_is_marked_as_created() {
  local ifb="$1"
  local state_file=""
  local dev=""

  state_file="$(ifb_created_state_file "$ifb")"
  [[ -r "$state_file" ]] || return 1

  dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
  dev="${dev%$'\r'}"
  if [[ "$dev" == "$ifb" ]]; then
    return 0
  fi

  rm -f "$state_file" 2>/dev/null || true
  return 1
}

clear_ifb_created_state() {
  local ifb="$1"
  local state_file=""

  state_file="$(ifb_created_state_file "$ifb")"
  rm -f "$state_file" 2>/dev/null || true
}

ifb_qdisc_state_file() {
  local dev="$1"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"

  echo "$OFFLOAD_STATE_DIR/ifb-qdisc-${safe}.state"
}

save_ifb_qdisc_state() {
  local ifb="$1"
  local state_file=""
  local tmp_file=""

  state_file="$(ifb_qdisc_state_file "$ifb")"
  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; IFB qdisc ownership marker is unavailable." >&2
    return 1
  fi

  tmp_file="${state_file}.tmp.$$"
  if printf '%s\n' "$ifb" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to save IFB qdisc ownership marker to '$state_file'." >&2
  return 1
}

ifb_qdisc_is_owned() {
  local ifb="$1"
  local state_file=""
  local dev=""

  state_file="$(ifb_qdisc_state_file "$ifb")"
  [[ -r "$state_file" ]] || return 1

  dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
  dev="${dev%$'\r'}"
  if [[ "$dev" == "$ifb" ]]; then
    return 0
  fi

  rm -f "$state_file" 2>/dev/null || true
  return 1
}

clear_ifb_qdisc_state() {
  local ifb="$1"
  local state_file=""

  state_file="$(ifb_qdisc_state_file "$ifb")"
  rm -f "$state_file" 2>/dev/null || true
}

should_skip_unowned_ifb_cleanup() {
  local ifb="$1"

  [[ "${ALLOW_IFB_REUSE,,}" == "yes" ]] && return 1
  ip link show "$ifb" >/dev/null 2>&1 || return 1
  is_ifb_device "$ifb" || return 1
  [[ "$(ifb_root_qdisc_kind "$ifb")" == "cake" ]] || return 1
  if ifb_is_marked_as_created "$ifb" || ifb_qdisc_is_owned "$ifb"; then
    return 1
  fi
  return 0
}

cleanup_ifb_qdisc_if_safe() {
  local ifb="$1"
  local root_kind=""

  if ! ip link show "$ifb" >/dev/null 2>&1; then
    return 0
  fi

  if ! is_ifb_device "$ifb"; then
    echo "WARN: '$ifb' exists but is not an ifb device; skipping IFB qdisc cleanup." >&2
    return 1
  fi

  root_kind="$(ifb_root_qdisc_kind "$ifb")"
  if [[ "$root_kind" != "cake" ]]; then
    clear_ifb_qdisc_state "$ifb"
    echo "INFO: Root qdisc on '$ifb' is not cake, skipping IFB root qdisc delete." >&2
    return 0
  fi

  if ! ifb_is_marked_as_created "$ifb" && ! ifb_qdisc_is_owned "$ifb"; then
    if [[ "${ALLOW_IFB_REUSE,,}" == "yes" ]]; then
      echo "WARN: IFB '$ifb' root cake is unmarked; deleting due to ALLOW_IFB_REUSE=yes." >&2
    else
      echo "ERROR: IFB '$ifb' root cake is unmarked; refusing to delete without ALLOW_IFB_REUSE=yes." >&2
      return 1
    fi
  fi

  tc qdisc del dev "$ifb" root 2>/dev/null || true

  if [[ "$(ifb_root_qdisc_kind "$ifb")" == "cake" ]]; then
    echo "ERROR: Failed to remove CAKE root qdisc on IFB '$ifb'." >&2
    return 1
  fi

  clear_ifb_qdisc_state "$ifb"
}

ifb_root_qdisc_kind() {
  local ifb="$1"
  local kind=""

  kind="$(tc qdisc show dev "$ifb" 2>/dev/null | awk '$4=="root" {print $2; exit}' || true)"
  echo "$kind"
}

validate_ifb_reuse_policy() {
  local ifb="$1"
  local root_kind=""

  case "${ALLOW_IFB_REUSE,,}" in
    yes|no) : ;;
    *)
      echo "ERROR: Invalid ALLOW_IFB_REUSE=$ALLOW_IFB_REUSE (use yes/no)." >&2
      return 1
      ;;
  esac

  root_kind="$(ifb_root_qdisc_kind "$ifb")"
  [[ -z "$root_kind" || "$root_kind" == "noqueue" ]] && return 0

  if [[ "$root_kind" == "cake" ]]; then
    if ifb_is_marked_as_created "$ifb" || ifb_qdisc_is_owned "$ifb"; then
      return 0
    fi
  fi

  if [[ "${ALLOW_IFB_REUSE,,}" == "yes" ]]; then
    echo "WARN: Reusing IFB '$ifb' with existing root qdisc '$root_kind' because ALLOW_IFB_REUSE=yes." >&2
    return 0
  fi

  if ifb_is_marked_as_created "$ifb" || ifb_qdisc_is_owned "$ifb"; then
    echo "ERROR: IFB '$ifb' has unexpected root qdisc '$root_kind' despite ownership marker." >&2
  else
    echo "ERROR: IFB '$ifb' already has root qdisc '$root_kind' and is not marked as created by this script." >&2
  fi
  echo "ERROR: Refusing to overwrite IFB root qdisc. Set ALLOW_IFB_REUSE=yes to force reuse." >&2
  return 1
}

delete_ifb_device_if_safe() {
  local ifb="$1"
  local root_kind=""

  if ! ip link show "$ifb" >/dev/null 2>&1; then
    clear_ifb_created_state "$ifb"
    clear_ifb_qdisc_state "$ifb"
    return 0
  fi

  case "${ALLOW_IFB_REUSE,,}" in
    yes|no) : ;;
    *)
      echo "ERROR: Invalid ALLOW_IFB_REUSE=$ALLOW_IFB_REUSE (use yes/no)." >&2
      return 1
      ;;
  esac

  if ! is_ifb_device "$ifb"; then
    echo "WARN: '$ifb' exists but is not an ifb device; skipping IFB device delete." >&2
    return 1
  fi

  if ! ifb_is_marked_as_created "$ifb"; then
    echo "INFO: '$ifb' is not marked as created by this script; skipping IFB device delete." >&2
    return 0
  fi

  root_kind="$(ifb_root_qdisc_kind "$ifb")"
  if [[ -z "$root_kind" ]]; then
    echo "ERROR: Cannot determine root qdisc kind on IFB '$ifb'; refusing to delete device." >&2
    return 1
  fi

  if [[ "$root_kind" != "noqueue" ]]; then
    if [[ "${ALLOW_IFB_REUSE,,}" == "yes" ]]; then
      echo "WARN: Deleting IFB '$ifb' with root qdisc '$root_kind' because ALLOW_IFB_REUSE=yes." >&2
    else
      echo "ERROR: IFB '$ifb' has root qdisc '$root_kind'; refusing device delete without ALLOW_IFB_REUSE=yes." >&2
      return 1
    fi
  fi

  ip link set "$ifb" down 2>/dev/null || true
  ip link del "$ifb" 2>/dev/null || true

  if ip link show "$ifb" >/dev/null 2>&1; then
    echo "ERROR: Failed to delete IFB device '$ifb'." >&2
    return 1
  fi

  clear_ifb_created_state "$ifb"
  clear_ifb_qdisc_state "$ifb"
}

delete_ingress_redirect_filters() {
  local wan="$1"

  # 兼容旧版本脚本遗留的 protocol all 规则
  tc filter del dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol all 2>/dev/null || true
  tc filter del dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ip 2>/dev/null || true
  tc filter del dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ipv6 2>/dev/null || true
}

add_ingress_redirect_filters() {
  local wan="$1"
  local ifb="$2"

  if ! tc filter add dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev "$ifb"; then
    echo "ERROR: Failed to install IPv4 ingress redirect filter on '$wan'." >&2
    return 1
  fi

  # 某些最小化内核/配置可能不支持 IPv6 过滤器；失败时降级为仅 IPv4。
  if ! tc filter add dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ipv6 u32 match u32 0 0 \
    action mirred egress redirect dev "$ifb"; then
    echo "WARN: Failed to install IPv6 ingress redirect filter on '$wan'; IPv6 ingress shaping is disabled." >&2
  fi
}

preflight_runtime_cmds() {
  require_cmd_or_exit ip
  require_cmd_or_exit tc
  require_cmd_or_exit awk
  require_cmd_or_exit grep
}

wan_if_state_file() {
  echo "$OFFLOAD_STATE_DIR/wan-if.state"
}

save_wan_if_state() {
  local dev="$1"
  local state_file=""
  local tmp_file=""

  state_file="$(wan_if_state_file)"
  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; WAN_IF pinning is disabled." >&2
    return 1
  fi

  tmp_file="${state_file}.tmp.$$"
  if printf '%s\n' "$dev" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to save WAN_IF state to '$state_file'." >&2
  return 1
}

load_wan_if_state() {
  local state_file=""
  local dev=""

  state_file="$(wan_if_state_file)"
  [[ -r "$state_file" ]] || return 1

  dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
  dev="${dev%$'\r'}"
  if [[ -z "$dev" ]]; then
    rm -f "$state_file" 2>/dev/null || true
    return 1
  fi

  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "WARN: Stored WAN_IF '$dev' is unavailable; keeping pinned WAN_IF for deterministic cleanup targeting." >&2
  fi

  echo "$dev"
}

resolve_control_wan_if() {
  local provided="$1"
  local pinned=""
  local root_owned=""
  local detected=""

  pinned="$(load_wan_if_state || true)"
  root_owned="$(load_root_cake_state || true)"

  if [[ -n "$provided" ]]; then
    if [[ -n "$pinned" && "$provided" != "$pinned" ]]; then
      if ip link show "$pinned" >/dev/null 2>&1; then
        echo "WARN: Provided WAN_IF '$provided' differs from pinned WAN_IF '$pinned'; using pinned WAN_IF." >&2
        echo "$pinned"
        return 0
      fi
      if [[ -n "$root_owned" && "$provided" != "$root_owned" ]] && ip link show "$root_owned" >/dev/null 2>&1; then
        echo "WARN: Pinned WAN_IF '$pinned' is unavailable; provided WAN_IF '$provided' differs from root-owned WAN_IF '$root_owned', using root-owned WAN_IF." >&2
        echo "$root_owned"
        return 0
      fi
      echo "WARN: Pinned WAN_IF '$pinned' is unavailable; honoring provided WAN_IF '$provided'." >&2
      echo "$provided"
      return 0
    fi
    if [[ -z "$pinned" && -n "$root_owned" && "$provided" != "$root_owned" ]]; then
      if ip link show "$root_owned" >/dev/null 2>&1; then
        echo "WARN: Provided WAN_IF '$provided' differs from root-owned WAN_IF '$root_owned'; using root-owned WAN_IF." >&2
        echo "$root_owned"
        return 0
      fi
      echo "WARN: Root-owned WAN_IF '$root_owned' is unavailable; honoring provided WAN_IF '$provided'." >&2
      echo "$provided"
      return 0
    fi
    echo "$provided"
    return 0
  fi

  if [[ -n "$pinned" ]]; then
    if ip link show "$pinned" >/dev/null 2>&1; then
      echo "$pinned"
      return 0
    fi
    if [[ -n "$root_owned" ]] && ip link show "$root_owned" >/dev/null 2>&1; then
      echo "WARN: Pinned WAN_IF '$pinned' is unavailable; using root-owned WAN_IF '$root_owned'." >&2
      echo "$root_owned"
      return 0
    fi
    echo "$pinned"
    return 0
  fi

  if [[ -n "$root_owned" ]]; then
    echo "$root_owned"
    return 0
  fi

  detected="$(detect_wan_if || true)"
  [[ -n "$detected" ]] && echo "$detected"
}

clear_wan_if_state() {
  local state_file=""
  state_file="$(wan_if_state_file)"
  rm -f "$state_file" 2>/dev/null || true
}

root_cake_state_file() {
  echo "$OFFLOAD_STATE_DIR/root-cake.state"
}

save_root_cake_state() {
  local dev="$1"
  local state_file=""
  local tmp_file=""

  state_file="$(root_cake_state_file)"
  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; root-cake ownership pinning is disabled." >&2
    return 1
  fi

  tmp_file="${state_file}.tmp.$$"
  if printf '%s\n' "$dev" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to save root-cake state to '$state_file'." >&2
  return 1
}

load_root_cake_state() {
  local state_file=""
  local dev=""

  state_file="$(root_cake_state_file)"
  [[ -r "$state_file" ]] || return 1

  dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
  dev="${dev%$'\r'}"
  if [[ -z "$dev" ]]; then
    rm -f "$state_file" 2>/dev/null || true
    return 1
  fi

  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "WARN: Stored root-cake interface '$dev' is unavailable; keeping marker for deterministic cleanup targeting." >&2
  fi

  echo "$dev"
}

clear_root_cake_state() {
  local state_file=""
  state_file="$(root_cake_state_file)"
  rm -f "$state_file" 2>/dev/null || true
}

offload_state_file() {
  local dev="$1"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"

  echo "$OFFLOAD_STATE_DIR/offload-${safe}.state"
}

capture_offload_state_if_needed() {
  local dev="$1"
  local state_file="$2"
  local tmp_file=""
  local tso=""
  local gso=""
  local gro=""

  if [[ -r "$state_file" && -s "$state_file" ]]; then
    tso="$(awk -F= '/^TSO=/{print $2; exit}' "$state_file" || true)"
    gso="$(awk -F= '/^GSO=/{print $2; exit}' "$state_file" || true)"
    gro="$(awk -F= '/^GRO=/{print $2; exit}' "$state_file" || true)"
    if [[ "$tso" =~ ^(on|off)$ && "$gso" =~ ^(on|off)$ && "$gro" =~ ^(on|off)$ ]]; then
      return 0
    fi
    echo "WARN: Existing offload state file '$state_file' is invalid; recapturing." >&2
    rm -f "$state_file" 2>/dev/null || true
  fi

  tso="$(ethtool -k "$dev" 2>/dev/null | awk '/^[[:space:]]*tcp-segmentation-offload:/ {print $2; exit}' || true)"
  gso="$(ethtool -k "$dev" 2>/dev/null | awk '/^[[:space:]]*generic-segmentation-offload:/ {print $2; exit}' || true)"
  gro="$(ethtool -k "$dev" 2>/dev/null | awk '/^[[:space:]]*generic-receive-offload:/ {print $2; exit}' || true)"

  if [[ "$tso" =~ ^(on|off)$ && "$gso" =~ ^(on|off)$ && "$gro" =~ ^(on|off)$ ]]; then
    if mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
      tmp_file="${state_file}.tmp.$$"
      if printf 'TSO=%s\nGSO=%s\nGRO=%s\n' "$tso" "$gso" "$gro" >"$tmp_file" 2>/dev/null && \
        mv -f "$tmp_file" "$state_file" 2>/dev/null; then
        return 0
      fi
      rm -f "$tmp_file" 2>/dev/null || true
    fi

    echo "WARN: Failed to save offload state to '$state_file'." >&2
    return 1
  fi

  echo "WARN: Could not read current tso/gso/gro state for '$dev'." >&2
  return 1
}

disable_offload_if_needed() {
  local dev="$1"
  local state_file=""

  [[ "${DISABLE_OFFLOAD,,}" == "yes" ]] || return 0
  if ! command -v ethtool >/dev/null 2>&1; then
    echo "WARN: ethtool not found; skipping offload disable on '$dev'." >&2
    return 0
  fi

  state_file="$(offload_state_file "$dev")"
  if ! capture_offload_state_if_needed "$dev" "$state_file"; then
    echo "WARN: Offload state is unavailable for '$dev'; skipping offload disable to keep stop/start reversible." >&2
    return 0
  fi

  # CAKE 整形前关闭网卡常见 offload，避免限速不准
  if ! ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1; then
    echo "WARN: Failed to disable tso/gso/gro on '$dev'; shaping accuracy may degrade." >&2
  fi
}

restore_offload_if_needed() {
  local dev="$1"
  local state_file=""
  local tso=""
  local gso=""
  local gro=""

  [[ "${DISABLE_OFFLOAD,,}" == "yes" ]] || return 0
  if ! command -v ethtool >/dev/null 2>&1; then
    echo "WARN: ethtool not found; skipping offload restore on '$dev'." >&2
    return 0
  fi

  state_file="$(offload_state_file "$dev")"
  if [[ ! -r "$state_file" ]]; then
    echo "INFO: Offload state file not found for '$dev'; skipping offload restore." >&2
    return 0
  fi

  tso="$(awk -F= '/^TSO=/{print $2; exit}' "$state_file" || true)"
  gso="$(awk -F= '/^GSO=/{print $2; exit}' "$state_file" || true)"
  gro="$(awk -F= '/^GRO=/{print $2; exit}' "$state_file" || true)"

  if [[ ! "$tso" =~ ^(on|off)$ || ! "$gso" =~ ^(on|off)$ || ! "$gro" =~ ^(on|off)$ ]]; then
    echo "WARN: Invalid offload state in '$state_file'; skipping restore." >&2
    rm -f "$state_file" 2>/dev/null || true
    return 1
  fi

  if ! ethtool -K "$dev" tso "$tso" gso "$gso" gro "$gro" >/dev/null 2>&1; then
    echo "WARN: Failed to restore tso/gso/gro on '$dev'; NIC may remain CPU-heavy." >&2
    return 1
  fi

  rm -f "$state_file" 2>/dev/null || true
}

has_root_cake_qdisc() {
  local dev="$1"

  tc qdisc show dev "$dev" 2>/dev/null | grep -qE '\bqdisc[[:space:]]+cake\b.*\broot\b'
}

remove_wan_cake_root_if_owned() {
  local dev="$1"
  local owner=""

  owner="$(load_root_cake_state || true)"
  if [[ -n "$owner" && "$owner" != "$dev" ]]; then
    if ip link show "$owner" >/dev/null 2>&1 && has_root_cake_qdisc "$owner"; then
      echo "WARN: Root CAKE marker points to '$owner' (current: '$dev') and '$owner' still has root CAKE; refusing to delete." >&2
      return 1
    fi
    echo "WARN: Root CAKE marker points to stale/unavailable '$owner'; allowing cleanup on '$dev' and clearing stale marker." >&2
    clear_root_cake_state
    owner=""
  fi

  if ! has_root_cake_qdisc "$dev"; then
    echo "INFO: Root qdisc on '$dev' is not cake, skipping root qdisc delete." >&2
    if [[ "$owner" == "$dev" ]]; then
      clear_root_cake_state
    fi
    return 0
  fi

  if [[ -z "$owner" ]]; then
    case "${ALLOW_UNOWNED_WAN_CAKE_DELETE,,}" in
      yes)
        echo "WARN: Root CAKE on '$dev' has no ownership marker; deleting due to ALLOW_UNOWNED_WAN_CAKE_DELETE=yes." >&2
        ;;
      no)
        echo "ERROR: Root CAKE on '$dev' has no ownership marker; refusing to delete." >&2
        echo "ERROR: Set ALLOW_UNOWNED_WAN_CAKE_DELETE=yes to allow legacy/unowned cleanup." >&2
        return 1
        ;;
      *)
        echo "ERROR: Invalid ALLOW_UNOWNED_WAN_CAKE_DELETE=$ALLOW_UNOWNED_WAN_CAKE_DELETE (use yes/no)." >&2
        return 1
        ;;
    esac
  fi

  tc qdisc del dev "$dev" root 2>/dev/null || true

  if has_root_cake_qdisc "$dev"; then
    echo "ERROR: Failed to remove CAKE root qdisc on '$dev'." >&2
    return 1
  fi

  clear_root_cake_state
}

apply_egress() {
  local dev="$1"
  local nf=""

  warn_virt_limits
  modprobe sch_cake 2>/dev/null || true

  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "ERROR: Interface '$dev' does not exist." >&2
    return 1
  fi

  local opts=()
  opts+=(bandwidth "$UP_BW")

  [[ -n "$DIFFSERV" ]] && opts+=("$DIFFSERV")
  [[ -n "$MODE" ]] && opts+=("$MODE")

  # NAT 参数
  case "$NAT" in
    yes)  opts+=(nat) ;;
    no)   : ;;
    auto) nf="$(nat_flag_auto)"; [[ -n "$nf" ]] && opts+=("$nf") ;;
    *)    echo "Invalid NAT=$NAT (use auto/yes/no)" >&2; return 1 ;;
  esac

  # RTT（可选）
  [[ -n "$RTT" ]] && opts+=(rtt "$RTT")

  # 额外参数（高级用法）
  if [[ -n "$EXTRA_CAKE_OPTS" ]]; then
    local extra_arr=()
    read -r -a extra_arr <<< "$EXTRA_CAKE_OPTS"
    opts+=("${extra_arr[@]}")
  fi

  # replace 为原子操作：存在则替换，不存在则创建
  if [[ "${ACK_FILTER,,}" == "yes" ]]; then
    if tc qdisc replace dev "$dev" root cake "${opts[@]}" ack-filter; then
      return 0
    fi
    echo "WARN: Failed to apply cake with ack-filter on '$dev'; retrying without ack-filter." >&2
  fi

  tc qdisc replace dev "$dev" root cake "${opts[@]}"
}

ensure_ifb_device() {
  local ifb="$1"
  local created_new=0

  warn_virt_limits
  modprobe ifb 2>/dev/null || true

  if ip link show "$ifb" >/dev/null 2>&1; then
    if ! is_ifb_device "$ifb"; then
      echo "ERROR: Interface '$ifb' exists but is not an ifb device." >&2
      return 1
    fi
  else
    ip link add "$ifb" type ifb
    created_new=1
  fi
  ip link set "$ifb" up

  if (( created_new == 1 )); then
    if ! save_ifb_created_state "$ifb"; then
      ip link set "$ifb" down 2>/dev/null || true
      ip link del "$ifb" 2>/dev/null || true
      echo "ERROR: IFB '$ifb' was created but ownership marker could not be saved; refusing to continue." >&2
      return 1
    fi
  fi
}

setup_ingress_redirect() {
  local wan="$1"
  local ifb="$2"

  warn_virt_limits
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_mirred 2>/dev/null || true

  if ! ip link show "$wan" >/dev/null 2>&1; then
    echo "ERROR: Interface '$wan' does not exist." >&2
    return 1
  fi
  if ! ip link show "$ifb" >/dev/null 2>&1; then
    echo "ERROR: Interface '$ifb' does not exist." >&2
    return 1
  fi

  # 确保 WAN 上有 ingress/clsact；避免删除他人的 ingress qdisc
  if ! tc qdisc show dev "$wan" 2>/dev/null | grep -qE '\b(ingress|clsact)\b'; then
    if ! tc qdisc add dev "$wan" handle ffff: ingress 2>/dev/null && \
      ! tc qdisc add dev "$wan" clsact; then
      echo "ERROR: Failed to create ingress/clsact qdisc on '$wan'." >&2
      return 1
    fi
  fi

  # 仅清理本脚本的 filter（按固定 pref）
  delete_ingress_redirect_filters "$wan"

  add_ingress_redirect_filters "$wan" "$ifb"
}

apply_ingress_via_ifb() {
  local wan="$1"
  local ifb="$2"
  local nf=""

  if [[ "$ifb" == "$wan" ]]; then
    echo "ERROR: IFB_DEV ('$ifb') must be different from WAN_IF ('$wan')." >&2
    return 1
  fi

  # DOWN_BW 为空视为显式关闭下行整形，并清理残留（仅清理本脚本 filter）
  if [[ -z "$DOWN_BW" ]]; then
    delete_ingress_redirect_filters "$wan"
    if should_skip_unowned_ifb_cleanup "$ifb"; then
      echo "INFO: IFB '$ifb' root cake is unmarked; leaving it untouched because ingress shaping is disabled." >&2
      return 0
    fi
    cleanup_ifb_qdisc_if_safe "$ifb" || return 1
    return 0
  fi

  local opts=()
  opts+=(bandwidth "$DOWN_BW")

  [[ -n "$DIFFSERV" ]] && opts+=("$DIFFSERV")
  [[ -n "$MODE" ]] && opts+=("$MODE")

  # 下行整形也可能需要 nat（仅当你是 NAT 网关）
  case "$NAT" in
    yes)  opts+=(nat) ;;
    no)   : ;;
    auto) nf="$(nat_flag_auto)"; [[ -n "$nf" ]] && opts+=("$nf") ;;
    *)    echo "Invalid NAT=$NAT (use auto/yes/no)" >&2; return 1 ;;
  esac

  [[ -n "$RTT" ]] && opts+=(rtt "$RTT")

  if [[ -n "$EXTRA_CAKE_OPTS" ]]; then
    local extra_arr=()
    read -r -a extra_arr <<< "$EXTRA_CAKE_OPTS"
    opts+=("${extra_arr[@]}")
  fi

  # 先配置 IFB 上的 CAKE，再接入 redirect，避免短暂的无整形窗口
  if ! ensure_ifb_device "$ifb"; then
    return 1
  fi
  if ! validate_ifb_reuse_policy "$ifb"; then
    return 1
  fi
  if ! tc qdisc replace dev "$ifb" root cake "${opts[@]}"; then
    echo "ERROR: Failed to apply CAKE root qdisc on IFB '$ifb'." >&2
    return 1
  fi
  if ! save_ifb_qdisc_state "$ifb"; then
    tc qdisc del dev "$ifb" root 2>/dev/null || true
    echo "ERROR: Failed to persist IFB qdisc ownership marker for '$ifb'; rolling back ingress qdisc apply." >&2
    return 1
  fi
  if ! setup_ingress_redirect "$wan" "$ifb"; then
    return 1
  fi
}

start() {
  preflight_runtime_cmds
  local existing_wan_state=""
  local existing_root_state=""
  local rollback_failed=0

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if || true)"
  fi
  [[ -z "$WAN_IF" ]] && { echo "Cannot detect WAN interface. Pass it as arg2." >&2; exit 1; }
  require_if_exists_or_exit "$WAN_IF"

  existing_wan_state="$(load_wan_if_state || true)"
  if [[ -n "$existing_wan_state" && "$existing_wan_state" != "$WAN_IF" ]]; then
    if ip link show "$existing_wan_state" >/dev/null 2>&1; then
      echo "ERROR: Existing WAN_IF state is pinned to '$existing_wan_state'. Stop it first, then start on '$WAN_IF'." >&2
      exit 1
    fi
    echo "WARN: Existing WAN_IF state '$existing_wan_state' is unavailable; repinning to '$WAN_IF'." >&2
    clear_wan_if_state
  fi

  existing_root_state="$(load_root_cake_state || true)"
  if [[ -n "$existing_root_state" && "$existing_root_state" != "$WAN_IF" ]]; then
    if ip link show "$existing_root_state" >/dev/null 2>&1; then
      echo "ERROR: Existing root-cake ownership points to '$existing_root_state'. Stop it first, then start on '$WAN_IF'." >&2
      exit 1
    fi
    echo "WARN: Existing root-cake marker '$existing_root_state' is unavailable; repinning to '$WAN_IF'." >&2
    clear_root_cake_state
  fi

  if ! save_wan_if_state "$WAN_IF"; then
    echo "ERROR: Failed to persist WAN_IF state; aborting to avoid cleanup targeting the wrong interface later." >&2
    exit 1
  fi
  if ! save_root_cake_state "$WAN_IF"; then
    echo "ERROR: Failed to persist root-cake ownership state; aborting to keep stop/restart deterministic." >&2
    clear_wan_if_state
    exit 1
  fi

  if ! disable_offload_if_needed "$WAN_IF"; then
    echo "ERROR: Failed before applying egress; clearing pinned state." >&2
    clear_root_cake_state
    clear_wan_if_state
    exit 1
  fi
  if ! apply_egress "$WAN_IF"; then
    echo "ERROR: Failed to apply egress CAKE; attempting rollback." >&2

    remove_wan_cake_root_if_owned "$WAN_IF" || rollback_failed=1
    restore_offload_if_needed "$WAN_IF" || rollback_failed=1

    if (( rollback_failed == 0 )); then
      clear_wan_if_state
      clear_root_cake_state
    else
      echo "WARN: Rollback after egress failure was incomplete; keeping state files for deterministic manual cleanup." >&2
    fi
    exit 1
  fi
  if ! apply_ingress_via_ifb "$WAN_IF" "$IFB_DEV"; then
    echo "ERROR: Failed to apply ingress shaping; attempting rollback." >&2

    # Best-effort rollback for partial start.
    delete_ingress_redirect_filters "$WAN_IF"
    if should_skip_unowned_ifb_cleanup "$IFB_DEV"; then
      echo "INFO: IFB '$IFB_DEV' root cake is unmarked; skipping IFB rollback cleanup." >&2
    else
      cleanup_ifb_qdisc_if_safe "$IFB_DEV" || rollback_failed=1
    fi
    remove_wan_cake_root_if_owned "$WAN_IF" || rollback_failed=1
    restore_offload_if_needed "$WAN_IF" || rollback_failed=1

    if (( rollback_failed == 0 )); then
      clear_wan_if_state
      clear_root_cake_state
    else
      echo "WARN: Rollback after start failure was incomplete; keeping state files for deterministic manual cleanup." >&2
    fi
    exit 1
  fi

  tc -s qdisc show dev "$WAN_IF" || true
  tc filter show dev "$WAN_IF" parent ffff: 2>/dev/null || true
  if ip link show "$IFB_DEV" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFB_DEV" || true
  fi
}

stop() {
  preflight_runtime_cmds
  local stop_failed=0
  local control_wan=""
  local wan_cleanup_confirmed=0
  local ifb_cleanup_ok=1

  control_wan="$(resolve_control_wan_if "${WAN_IF-}" || true)"

  if [[ -n "$control_wan" ]]; then
    if ! ip link show "$control_wan" >/dev/null 2>&1; then
      echo "WARN: Resolved WAN interface '$control_wan' does not exist, skipping WAN qdisc cleanup." >&2
      stop_failed=1
    else
      if remove_wan_cake_root_if_owned "$control_wan"; then
        wan_cleanup_confirmed=1
        delete_ingress_redirect_filters "$control_wan"
        restore_offload_if_needed "$control_wan" || stop_failed=1
      else
        echo "WARN: Skipping additional WAN cleanup on '$control_wan' because root CAKE ownership cleanup failed." >&2
        stop_failed=1
      fi
    fi
  else
    echo "WARN: Cannot detect WAN interface, skipping WAN qdisc cleanup." >&2
    stop_failed=1
  fi

  # IFB 清理（默认不删设备，避免影响其他服务）
  if (( wan_cleanup_confirmed == 1 )); then
    if [[ -n "$control_wan" && "$IFB_DEV" == "$control_wan" ]]; then
      echo "WARN: IFB_DEV ('$IFB_DEV') matches WAN_IF; skipping IFB cleanup to avoid touching WAN root qdisc." >&2
      stop_failed=1
    else
      if should_skip_unowned_ifb_cleanup "$IFB_DEV"; then
        echo "INFO: IFB '$IFB_DEV' root cake is unmarked; skipping IFB cleanup." >&2
      else
        if ! cleanup_ifb_qdisc_if_safe "$IFB_DEV"; then
          stop_failed=1
          ifb_cleanup_ok=0
        fi
      fi
      if [[ "${DELETE_IFB_ON_STOP,,}" == "yes" && "$ifb_cleanup_ok" -eq 1 ]]; then
        delete_ifb_device_if_safe "$IFB_DEV" || stop_failed=1
      elif [[ "${DELETE_IFB_ON_STOP,,}" == "yes" ]]; then
        echo "WARN: Skipping IFB device delete because IFB qdisc cleanup failed." >&2
      fi
    fi
  else
    echo "WARN: Skipping IFB cleanup because WAN cleanup target was not confirmed." >&2
  fi

  if (( stop_failed == 0 )); then
    clear_wan_if_state
    clear_root_cake_state
    return 0
  fi

  return 1
}

status() {
  preflight_runtime_cmds
  local control_wan=""

  control_wan="$(resolve_control_wan_if "${WAN_IF-}" || true)"
  [[ -z "$control_wan" ]] && { echo "Cannot detect WAN interface."; exit 1; }
  if ! ip link show "$control_wan" >/dev/null 2>&1; then
    echo "ERROR: Interface '$control_wan' does not exist." >&2
    exit 1
  fi

  tc -s qdisc show dev "$control_wan" || true
  tc filter show dev "$control_wan" parent ffff: 2>/dev/null || true
  if ip link show "$IFB_DEV" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFB_DEV" || true
  fi
}

case "$CMD" in
  start)   start ;;
  stop)    stop ;;
  restart)
    restart_target="$(resolve_control_wan_if "${WAN_IF-}" || true)"
    if [[ -n "${restart_target-}" ]] && ! ip link show "$restart_target" >/dev/null 2>&1; then
      echo "WARN: Resolved restart WAN_IF '$restart_target' does not exist; falling back to auto-detection." >&2
      restart_target="$(detect_wan_if || true)"
    fi
    restart_stop_failed=0
    if ! stop; then
      restart_stop_failed=1
      echo "WARN: stop failed during restart; proceeding with start." >&2
    fi
    WAN_IF="${restart_target-}"
    start
    (( restart_stop_failed == 0 )) || exit 2
    ;;
  status)  status ;;
  *) echo "Usage: $0 {start|stop|restart|status} [WAN_IF]" >&2; exit 1 ;;
esac
