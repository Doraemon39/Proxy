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
INGRESS_PREF="${INGRESS_PREF:-49152}"           # 用固定 pref 标记本脚本创建的 ingress filter

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

  tc filter add dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev "$ifb"

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

disable_offload_if_needed() {
  local dev="$1"

  [[ "${DISABLE_OFFLOAD,,}" == "yes" ]] || return 0
  if ! command -v ethtool >/dev/null 2>&1; then
    echo "WARN: ethtool not found; skipping offload disable on '$dev'." >&2
    return 0
  fi

  # CAKE 整形前关闭网卡常见 offload，避免限速不准
  if ! ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1; then
    echo "WARN: Failed to disable tso/gso/gro on '$dev'; shaping accuracy may degrade." >&2
  fi
}

apply_egress() {
  local dev="$1"

  warn_virt_limits
  modprobe sch_cake 2>/dev/null || true

  require_if_exists_or_exit "$dev"

  local opts=()
  opts+=(bandwidth "$UP_BW")

  [[ -n "$DIFFSERV" ]] && opts+=("$DIFFSERV")
  [[ -n "$MODE" ]] && opts+=("$MODE")

  # NAT 参数
  case "$NAT" in
    yes)  opts+=(nat) ;;
    no)   : ;;
    auto) nf="$(nat_flag_auto)"; [[ -n "$nf" ]] && opts+=("$nf") ;;
    *)    echo "Invalid NAT=$NAT (use auto/yes/no)" >&2; exit 1 ;;
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

  warn_virt_limits
  modprobe ifb 2>/dev/null || true

  if ! ip link show "$ifb" >/dev/null 2>&1; then
    ip link add "$ifb" type ifb
  fi
  ip link set "$ifb" up
}

setup_ingress_redirect() {
  local wan="$1"
  local ifb="$2"

  warn_virt_limits
  modprobe sch_ingress 2>/dev/null || true
  modprobe cls_u32 2>/dev/null || true
  modprobe act_mirred 2>/dev/null || true

  require_if_exists_or_exit "$wan"
  require_if_exists_or_exit "$ifb"

  # 确保 WAN 上有 ingress/clsact；避免删除他人的 ingress qdisc
  if ! tc qdisc show dev "$wan" 2>/dev/null | grep -qE '\b(ingress|clsact)\b'; then
    tc qdisc add dev "$wan" handle ffff: ingress 2>/dev/null || tc qdisc add dev "$wan" clsact
  fi

  # 仅清理本脚本的 filter（按固定 pref）
  delete_ingress_redirect_filters "$wan"

  add_ingress_redirect_filters "$wan" "$ifb"
}

apply_ingress_via_ifb() {
  local wan="$1"
  local ifb="$2"

  # DOWN_BW 为空视为显式关闭下行整形，并清理残留（仅清理本脚本 filter）
  if [[ -z "$DOWN_BW" ]]; then
    delete_ingress_redirect_filters "$wan"
    tc qdisc del dev "$ifb" root 2>/dev/null || true
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
    *)    echo "Invalid NAT=$NAT (use auto/yes/no)" >&2; exit 1 ;;
  esac

  [[ -n "$RTT" ]] && opts+=(rtt "$RTT")

  if [[ -n "$EXTRA_CAKE_OPTS" ]]; then
    local extra_arr=()
    read -r -a extra_arr <<< "$EXTRA_CAKE_OPTS"
    opts+=("${extra_arr[@]}")
  fi

  # 先配置 IFB 上的 CAKE，再接入 redirect，避免短暂的无整形窗口
  ensure_ifb_device "$ifb"
  tc qdisc replace dev "$ifb" root cake "${opts[@]}"
  setup_ingress_redirect "$wan" "$ifb"
}

start() {
  preflight_runtime_cmds

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if || true)"
  fi
  [[ -z "$WAN_IF" ]] && { echo "Cannot detect WAN interface. Pass it as arg2." >&2; exit 1; }

  disable_offload_if_needed "$WAN_IF"
  apply_egress "$WAN_IF"
  apply_ingress_via_ifb "$WAN_IF" "$IFB_DEV"

  tc -s qdisc show dev "$WAN_IF" || true
  tc filter show dev "$WAN_IF" parent ffff: 2>/dev/null || true
  if ip link show "$IFB_DEV" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFB_DEV" || true
  fi
}

stop() {
  preflight_runtime_cmds

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if || true)"
  fi

  if [[ -n "$WAN_IF" ]]; then
    # 避免误删其他程序配置的非-cake root qdisc
    if tc qdisc show dev "$WAN_IF" 2>/dev/null | grep -qE '\bqdisc[[:space:]]+cake\b.*\broot\b'; then
      tc qdisc del dev "$WAN_IF" root 2>/dev/null || true
    else
      echo "INFO: Root qdisc on '$WAN_IF' is not cake, skipping root qdisc delete." >&2
    fi
    delete_ingress_redirect_filters "$WAN_IF"
  else
    echo "WARN: Cannot detect WAN interface, skipping WAN qdisc cleanup." >&2
  fi

  # IFB 清理（默认不删设备，避免影响其他服务）
  tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
  if [[ "${DELETE_IFB_ON_STOP,,}" == "yes" ]]; then
    ip link set "$IFB_DEV" down 2>/dev/null || true
    ip link del "$IFB_DEV" 2>/dev/null || true
  fi
}

status() {
  preflight_runtime_cmds

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if || true)"
  fi
  [[ -z "$WAN_IF" ]] && { echo "Cannot detect WAN interface."; exit 1; }

  tc -s qdisc show dev "$WAN_IF" || true
  tc filter show dev "$WAN_IF" parent ffff: 2>/dev/null || true
  if ip link show "$IFB_DEV" >/dev/null 2>&1; then
    tc -s qdisc show dev "$IFB_DEV" || true
  fi
}

case "$CMD" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  *) echo "Usage: $0 {start|stop|restart|status} [WAN_IF]" >&2; exit 1 ;;
esac
