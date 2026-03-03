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

# ===== Defaults =====
UP_BW="${UP_BW:-20mbit}"                # Required; default if unset.
MODE="${MODE-"triple-isolate"}"         # Use "-" expansion to allow empty value.
DIFFSERV="${DIFFSERV-"diffserv4"}"      # Allow DIFFSERV="" to disable DiffServ mode.
NAT="${NAT:-no}"
ACK_FILTER="${ACK_FILTER:-yes}"
RTT="${RTT-}"                           # Optional.
DOWN_BW="${DOWN_BW-}"                   # Optional; empty disables ingress shaping.
IFB_DEV="${IFB_DEV:-ifb0}"
EXTRA_CAKE_OPTS="${EXTRA_CAKE_OPTS-}"
DISABLE_OFFLOAD="${DISABLE_OFFLOAD:-yes}"  # yes/no; default yes, disable WAN tso/gso/gro.
DELETE_IFB_ON_STOP="${DELETE_IFB_ON_STOP:-no}"  # yes/no; delete IFB device on stop when yes.
ALLOW_IFB_REUSE="${ALLOW_IFB_REUSE:-no}"        # yes/no; allow reusing non-owned IFB root qdisc.
ALLOW_UNOWNED_WAN_CAKE_DELETE="${ALLOW_UNOWNED_WAN_CAKE_DELETE:-no}"  # yes/no; allow deleting unowned WAN root CAKE.
RESTART_CONTINUE_ON_STOP_FAILURE="${RESTART_CONTINUE_ON_STOP_FAILURE:-no}"  # yes/no; continue restart start-phase if stop fails.
INGRESS_PREF="${INGRESS_PREF:-49152}"           # Fixed pref used by this script's ingress filters.
OFFLOAD_STATE_DIR="${OFFLOAD_STATE_DIR:-/run/qos-cake}"  # Directory for runtime state files.
OFFLOAD_STATE_COMPAT_DIRS="${OFFLOAD_STATE_COMPAT_DIRS-}"  # Optional ":"-separated legacy state dirs for migration reads/cleanup.
OFFLOAD_STATE_LEGACY_DIR="${OFFLOAD_STATE_LEGACY_DIR:-/run/qos-cake}"  # Built-in legacy state dir for backward-compatible reads/cleanup.
ALLOW_ROOT_STATE_GLOBAL_SCAN="${ALLOW_ROOT_STATE_GLOBAL_SCAN:-no}"  # yes/no; allow expensive '/' scan to locate legacy root-cake.state.

if [[ ! "$INGRESS_PREF" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Invalid INGRESS_PREF='$INGRESS_PREF' (use digits only)." >&2
  exit 1
fi

LOCK_FILE="${LOCK_FILE:-$OFFLOAD_STATE_DIR/qos-cake.lock}"
LOCK_PID_FILE="${LOCK_PID_FILE:-$OFFLOAD_STATE_DIR/qos-cake.lock.pid}"

CMD="${1:-}"
WAN_IF="${WAN_IF-}"
if [[ -n "${2:-}" ]]; then
  WAN_IF="$2"
fi
GLOBAL_LOCK_HELD=0
GLOBAL_LOCK_KIND="none"
STATE_DIR_DISCOVERY_CACHE=""
STATE_DIR_DISCOVERY_READY=0

warn_virt_limits() {
  # Common LXC/OpenVZ limitation: modprobe or IFB creation may be blocked.
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
  # Prefer IPv4 route lookup, then fall back to IPv6.
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
  # Detect NAT rules (MASQUERADE/masquerade) via nftables or iptables.
  local nft_ruleset=""
  local ipt_rules=""
  if command -v nft >/dev/null 2>&1; then
    nft_ruleset="$(nft list ruleset 2>/dev/null || true)"
    if grep -qiE '(^|[[:space:]])masquerade([[:space:]]|$)' <<<"$nft_ruleset"; then
      echo "nat"
      return 0
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    ipt_rules="$(iptables -t nat -S 2>/dev/null || true)"
    if grep -qE '(^|[[:space:]])-j[[:space:]]+MASQUERADE([[:space:]]|$)' <<<"$ipt_rules"; then
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
  local ifb_names=""

  ifb_names="$(ip -o link show type ifb 2>/dev/null | \
    awk -F': ' '{name=$2; sub(/@.*/, "", name); print name}' || true)"
  grep -Fxq "$dev" <<<"$ifb_names"
}

discover_state_dirs_from_markers() {
  local search_root=""
  local state_file=""
  local dir=""
  local -A seen_roots=()
  local -A seen_dirs=()

  if (( STATE_DIR_DISCOVERY_READY == 1 )); then
    [[ -n "$STATE_DIR_DISCOVERY_CACHE" ]] && printf '%s\n' "$STATE_DIR_DISCOVERY_CACHE"
    return 0
  fi
  STATE_DIR_DISCOVERY_READY=1
  STATE_DIR_DISCOVERY_CACHE=""

  if ! command -v find >/dev/null 2>&1; then
    return 0
  fi

  for search_root in "/run" "/var/run" "${OFFLOAD_STATE_DIR%/*}" "${OFFLOAD_STATE_LEGACY_DIR%/*}"; do
    search_root="${search_root%/}"
    [[ -z "$search_root" || "$search_root" == "." || "$search_root" == "/" ]] && continue
    [[ -d "$search_root" ]] || continue
    [[ -n "${seen_roots[$search_root]+x}" ]] && continue
    seen_roots["$search_root"]=1

    while IFS= read -r state_file; do
      [[ -n "$state_file" ]] || continue
      dir="${state_file%/*}"
      [[ -n "$dir" ]] || continue
      [[ -n "${seen_dirs[$dir]+x}" ]] && continue
      seen_dirs["$dir"]=1

      if [[ -z "$STATE_DIR_DISCOVERY_CACHE" ]]; then
        STATE_DIR_DISCOVERY_CACHE="$dir"
      else
        STATE_DIR_DISCOVERY_CACHE+=$'\n'"$dir"
      fi
    done < <(
      find "$search_root" -maxdepth 5 -type f \
        \( -name 'root-cake.state' -o -name 'wan-if.state' -o -name 'ingress-qdisc.state' -o -name 'offload-*.state' -o -name 'ifb-created-*.state' -o -name 'ifb-qdisc-*.state' \) \
        2>/dev/null || true
    )
  done

  [[ -n "$STATE_DIR_DISCOVERY_CACHE" ]] && printf '%s\n' "$STATE_DIR_DISCOVERY_CACHE"
}

state_dir_candidates() {
  local entry=""
  local -a compat_dirs=()
  local -A seen=()

  entry="${OFFLOAD_STATE_DIR%/}"
  if [[ -n "$entry" ]]; then
    seen["$entry"]=1
    echo "$entry"
  fi

  if [[ -n "${OFFLOAD_STATE_COMPAT_DIRS//[[:space:]]/}" ]]; then
    IFS=':' read -r -a compat_dirs <<<"$OFFLOAD_STATE_COMPAT_DIRS"
    for entry in "${compat_dirs[@]}"; do
      entry="${entry%/}"
      [[ -z "$entry" ]] && continue
      if [[ -z "${seen[$entry]+x}" ]]; then
        seen["$entry"]=1
        echo "$entry"
      fi
    done
  fi

  for entry in "$OFFLOAD_STATE_LEGACY_DIR" "/run/qos-cake" "/var/run/qos-cake"; do
    entry="${entry%/}"
    [[ -z "$entry" ]] && continue
    if [[ -z "${seen[$entry]+x}" ]]; then
      seen["$entry"]=1
      echo "$entry"
    fi
  done

  while IFS= read -r entry; do
    entry="${entry%/}"
    [[ -z "$entry" ]] && continue
    if [[ -z "${seen[$entry]+x}" ]]; then
      seen["$entry"]=1
      echo "$entry"
    fi
  done < <(discover_state_dirs_from_markers)
}

ifb_created_state_file() {
  local dev="$1"
  ifb_created_state_file_for_dir "$OFFLOAD_STATE_DIR" "$dev"
}

ifb_created_state_file_for_dir() {
  local dir="$1"
  local dev="$2"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"
  dir="${dir%/}"

  echo "$dir/ifb-created-${safe}.state"
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
  local dir=""
  local state_file=""
  local dev=""

  while IFS= read -r dir; do
    state_file="$(ifb_created_state_file_for_dir "$dir" "$ifb")"
    [[ -r "$state_file" ]] || continue

    dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    dev="${dev%$'\r'}"
    if [[ "$dev" == "$ifb" ]]; then
      return 0
    fi

    rm -f "$state_file" 2>/dev/null || true
  done < <(state_dir_candidates)

  return 1
}

clear_ifb_created_state() {
  local ifb="$1"
  local dir=""
  local state_file=""

  while IFS= read -r dir; do
    state_file="$(ifb_created_state_file_for_dir "$dir" "$ifb")"
    rm -f "$state_file" 2>/dev/null || true
  done < <(state_dir_candidates)
}

ifb_qdisc_state_file() {
  local dev="$1"
  ifb_qdisc_state_file_for_dir "$OFFLOAD_STATE_DIR" "$dev"
}

ifb_qdisc_state_file_for_dir() {
  local dir="$1"
  local dev="$2"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"
  dir="${dir%/}"

  echo "$dir/ifb-qdisc-${safe}.state"
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
  local dir=""
  local state_file=""
  local dev=""

  while IFS= read -r dir; do
    state_file="$(ifb_qdisc_state_file_for_dir "$dir" "$ifb")"
    [[ -r "$state_file" ]] || continue

    dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    dev="${dev%$'\r'}"
    if [[ "$dev" == "$ifb" ]]; then
      return 0
    fi

    rm -f "$state_file" 2>/dev/null || true
  done < <(state_dir_candidates)

  return 1
}

clear_ifb_qdisc_state() {
  local ifb="$1"
  local dir=""
  local state_file=""

  while IFS= read -r dir; do
    state_file="$(ifb_qdisc_state_file_for_dir "$dir" "$ifb")"
    rm -f "$state_file" 2>/dev/null || true
  done < <(state_dir_candidates)
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
  local default_kind=""
  local post_kind=""

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

  if ! tc qdisc del dev "$ifb" root 2>/dev/null; then
    echo "ERROR: Failed to remove CAKE root qdisc on IFB '$ifb'." >&2
    return 1
  fi

  post_kind="$(ifb_root_qdisc_kind "$ifb")"
  if [[ "$post_kind" == "cake" ]]; then
    default_kind="$(kernel_default_qdisc_kind)"
    if [[ "$default_kind" != "cake" ]]; then
      echo "ERROR: Failed to remove CAKE root qdisc on IFB '$ifb'." >&2
      return 1
    fi
    # default_qdisc=cake may re-attach a fresh default CAKE after deletion.
    clear_ifb_qdisc_state "$ifb"
    return 0
  fi

  if [[ "$post_kind" == "$root_kind" ]]; then
    echo "ERROR: Failed to remove CAKE root qdisc on IFB '$ifb'." >&2
    return 1
  fi

  clear_ifb_qdisc_state "$ifb"
}

ifb_root_qdisc_kind() {
  local ifb="$1"
  local kind=""

  kind="$(tc qdisc show dev "$ifb" 2>/dev/null | awk '
    $1 == "qdisc" {
      kind = $2
      for (i = 1; i <= NF; i++) {
        if ($i == "root") {
          print kind
          exit
        }
      }
    }
  ' || true)"
  echo "$kind"
}

kernel_default_qdisc_kind() {
  local kind=""

  if [[ -r /proc/sys/net/core/default_qdisc ]]; then
    read -r kind </proc/sys/net/core/default_qdisc || true
  elif command -v sysctl >/dev/null 2>&1; then
    kind="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  fi

  kind="${kind%%[[:space:]]*}"
  echo "$kind"
}

validate_ifb_reuse_policy() {
  local ifb="$1"
  local root_kind=""
  local default_kind=""

  case "${ALLOW_IFB_REUSE,,}" in
    yes|no) : ;;
    *)
      echo "ERROR: Invalid ALLOW_IFB_REUSE=$ALLOW_IFB_REUSE (use yes/no)." >&2
      return 1
      ;;
  esac

  root_kind="$(ifb_root_qdisc_kind "$ifb")"
  [[ -z "$root_kind" || "$root_kind" == "noqueue" ]] && return 0

  # Kernel may auto-attach the default qdisc when IFB is brought up,
  # and stop() may intentionally leave IFB with that default qdisc.
  default_kind="$(kernel_default_qdisc_kind)"
  if [[ -n "$default_kind" && "$root_kind" == "$default_kind" ]]; then
    return 0
  fi

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
  local default_kind=""

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

  default_kind="$(kernel_default_qdisc_kind)"
  if [[ "$root_kind" != "noqueue" ]]; then
    if [[ -n "$default_kind" && "$root_kind" == "$default_kind" ]]; then
      :
    elif [[ "${ALLOW_IFB_REUSE,,}" == "yes" ]]; then
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

list_script_ingress_redirect_specs_for_ifb() {
  local wan="$1"
  local ifb="$2"
  local filter_dump=""

  filter_dump="$(tc filter show dev "$wan" parent ffff: 2>/dev/null || true)"
  if [[ -z "${filter_dump//[[:space:]]/}" ]]; then
    filter_dump="$(tc filter show dev "$wan" ingress 2>/dev/null || true)"
  fi
  [[ -n "${filter_dump//[[:space:]]/}" ]] || return 0

  awk -v ifb="$ifb" '
    BEGIN {
      want = tolower(ifb)
      pref = ""
      proto = ""
      handle = ""
      has_u32 = 0
      has_u32_matchall = 0
      has_ifb_redirect = 0
    }
    function reset_state() {
      pref = ""
      proto = ""
      handle = ""
      has_u32 = 0
      has_u32_matchall = 0
      has_ifb_redirect = 0
    }
    function emit_if_match() {
      if (pref != "" && proto != "" && handle != "" && has_u32 == 1 && has_u32_matchall == 1 && has_ifb_redirect == 1) {
        print pref "|" proto "|" handle
      }
      reset_state()
    }
    /^[[:space:]]*filter[[:space:]]/ {
      emit_if_match()
      for (i = 1; i <= NF; i++) {
        if ($i == "pref" && (i + 1) <= NF) {
          pref = $(i + 1)
          gsub(/[^0-9].*$/, "", pref)
          continue
        }
        if ($i == "protocol" && (i + 1) <= NF) {
          proto = tolower($(i + 1))
          gsub(/[^[:alnum:]_.:-].*$/, "", proto)
          continue
        }
        if (($i == "fh" || $i == "handle") && (i + 1) <= NF) {
          handle = tolower($(i + 1))
          gsub(/[^0-9a-fx:]/, "", handle)
          continue
        }
        if ($i == "u32") {
          has_u32 = 1
        }
      }
      next
    }
    {
      line = tolower($0)
      if (index(line, "match 00000000/00000000") > 0) {
        has_u32_matchall = 1
      }
      if (index(line, "mirred") > 0 && index(line, "redirect") > 0) {
        # tc may print either "dev <ifname>" or "to device <ifname>".
        normalized = line
        gsub(/[()]/, " ", normalized)
        n = split(normalized, fields, /[[:space:]]+/)
        for (i = 1; i < n; i++) {
          if (fields[i] == "dev" || fields[i] == "device") {
            candidate = fields[i + 1]
            gsub(/[^[:alnum:]_.:-].*$/, "", candidate)
            if (candidate == want) {
              has_ifb_redirect = 1
              break
            }
          }
        }
      }
    }
    END {
      emit_if_match()
    }
  ' <<<"$filter_dump" | awk -F'|' 'NF == 3 && !seen[$0]++'
}

list_script_ingress_redirect_prefs_for_ifb() {
  local wan="$1"
  local ifb="$2"
  local filter_dump=""

  filter_dump="$(tc filter show dev "$wan" parent ffff: 2>/dev/null || true)"
  if [[ -z "${filter_dump//[[:space:]]/}" ]]; then
    filter_dump="$(tc filter show dev "$wan" ingress 2>/dev/null || true)"
  fi
  [[ -n "${filter_dump//[[:space:]]/}" ]] || return 0

  awk -v ifb="$ifb" '
    BEGIN {
      want = tolower(ifb)
      pref = ""
      has_u32_matchall = 0
      has_ifb_redirect = 0
    }
    function emit_if_match() {
      if (pref != "" && has_u32_matchall == 1 && has_ifb_redirect == 1) {
        print pref
      }
      pref = ""
      has_u32_matchall = 0
      has_ifb_redirect = 0
    }
    /^[[:space:]]*filter[[:space:]]/ {
      emit_if_match()
      for (i = 1; i <= NF; i++) {
        if ($i == "pref" && (i + 1) <= NF) {
          pref = $(i + 1)
          gsub(/[^0-9].*$/, "", pref)
          break
        }
      }
      next
    }
    {
      line = tolower($0)
      if (index(line, "match 00000000/00000000") > 0) {
        has_u32_matchall = 1
      }
      if (index(line, "mirred") > 0 && index(line, "redirect") > 0) {
        # tc may print either "dev <ifname>" or "to device <ifname>".
        normalized = line
        gsub(/[()]/, " ", normalized)
        n = split(normalized, fields, /[[:space:]]+/)
        for (i = 1; i < n; i++) {
          if (fields[i] == "dev" || fields[i] == "device") {
            candidate = fields[i + 1]
            gsub(/[^[:alnum:]_.:-].*$/, "", candidate)
            if (candidate == want) {
              has_ifb_redirect = 1
              break
            }
          }
        }
      }
    }
    END {
      emit_if_match()
    }
  ' <<<"$filter_dump" | awk 'NF && !seen[$0]++'
}

list_marked_ifb_qdisc_devices() {
  local dir=""
  local state_file=""
  local dev=""

  while IFS= read -r dir; do
    for state_file in "$dir"/ifb-qdisc-*.state; do
      [[ -r "$state_file" ]] || continue

      dev="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
      dev="${dev%$'\r'}"
      if [[ -z "$dev" ]]; then
        rm -f "$state_file" 2>/dev/null || true
        continue
      fi
      echo "$dev"
    done
  done < <(state_dir_candidates) | awk 'NF && !seen[$0]++'
}

list_ingress_redirect_cleanup_ifb_candidates() {
  local preferred_ifb="${1-}"
  local candidate=""
  local -A seen=()

  if [[ -n "$preferred_ifb" ]]; then
    seen["$preferred_ifb"]=1
    echo "$preferred_ifb"
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ -z "${seen[$candidate]+x}" ]]; then
      seen["$candidate"]=1
      echo "$candidate"
    fi
  done < <(list_marked_ifb_qdisc_devices)
}

delete_ingress_redirect_filter_spec() {
  local wan="$1"
  local pref="$2"
  local proto="$3"
  local handle="$4"

  [[ "$pref" =~ ^[0-9]+$ ]] || return 0
  case "$proto" in
    all|ip|ipv6) : ;;
    *) return 0 ;;
  esac
  [[ "$handle" =~ ^[0-9a-fx:]+$ ]] || return 0

  # Delete only the exact script-managed u32 filter to avoid removing unrelated rules
  # that happen to share the same pref/protocol.
  tc filter del dev "$wan" parent ffff: protocol "$proto" pref "$pref" handle "$handle" u32 2>/dev/null || \
    tc filter del dev "$wan" parent ffff: protocol "$proto" prio "$pref" handle "$handle" u32 2>/dev/null || \
    tc filter del dev "$wan" ingress protocol "$proto" pref "$pref" handle "$handle" u32 2>/dev/null || \
    tc filter del dev "$wan" ingress protocol "$proto" prio "$pref" handle "$handle" u32 2>/dev/null || true
}

delete_ingress_redirect_filters() {
  local wan="$1"
  local ifb="${2-}"
  local spec=""
  local pref=""
  local proto=""
  local handle=""
  local candidate_ifb=""
  local -A seen_specs=()

  while IFS= read -r candidate_ifb; do
    [[ -n "$candidate_ifb" ]] || continue
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      if [[ -n "${seen_specs[$spec]+x}" ]]; then
        continue
      fi
      seen_specs["$spec"]=1

      IFS='|' read -r pref proto handle <<<"$spec"
      [[ -n "$pref" && -n "$proto" && -n "$handle" ]] || continue
      delete_ingress_redirect_filter_spec "$wan" "$pref" "$proto" "$handle"
    done < <(list_script_ingress_redirect_specs_for_ifb "$wan" "$candidate_ifb")
  done < <(list_ingress_redirect_cleanup_ifb_candidates "$ifb")
}

has_script_ingress_redirect_filters() {
  local wan="$1"
  local ifb="${2-}"
  local filter_dump=""
  local found_legacy_prefs=""
  local candidate_ifb=""

  if [[ -n "$ifb" ]]; then
    while IFS= read -r candidate_ifb; do
      [[ -n "$candidate_ifb" ]] || continue
      found_legacy_prefs="$(list_script_ingress_redirect_prefs_for_ifb "$wan" "$candidate_ifb" || true)"
      if [[ -n "${found_legacy_prefs//[[:space:]]/}" ]]; then
        return 0
      fi
    done < <(list_ingress_redirect_cleanup_ifb_candidates "$ifb")
    return 1
  fi

  filter_dump="$(tc filter show dev "$wan" parent ffff: 2>/dev/null || true)"
  if [[ -z "${filter_dump//[[:space:]]/}" ]]; then
    filter_dump="$(tc filter show dev "$wan" ingress 2>/dev/null || true)"
  fi

  grep -qE "(^|[[:space:]])pref[[:space:]]+$INGRESS_PREF([[:space:]]|$)" <<<"$filter_dump"
}

ingress_qdisc_state_file_for_dir() {
  local dir="$1"
  dir="${dir%/}"
  echo "$dir/ingress-qdisc.state"
}

ingress_qdisc_state_file() {
  ingress_qdisc_state_file_for_dir "$OFFLOAD_STATE_DIR"
}

save_ingress_qdisc_state() {
  local dev="$1"
  local state_file=""
  local tmp_file=""

  state_file="$(ingress_qdisc_state_file)"
  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; ingress qdisc ownership marker is unavailable." >&2
    return 1
  fi

  tmp_file="${state_file}.tmp.$$"
  if printf '%s\n' "$dev" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to save ingress qdisc ownership marker to '$state_file'." >&2
  return 1
}

ingress_qdisc_is_owned() {
  local dev="$1"
  local dir=""
  local state_file=""
  local owner=""

  while IFS= read -r dir; do
    state_file="$(ingress_qdisc_state_file_for_dir "$dir")"
    [[ -r "$state_file" ]] || continue

    owner="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    owner="${owner%$'\r'}"
    if [[ "$owner" == "$dev" ]]; then
      return 0
    fi

    if [[ -z "$owner" ]]; then
      rm -f "$state_file" 2>/dev/null || true
    fi
  done < <(state_dir_candidates)

  return 1
}

clear_ingress_qdisc_state() {
  local dir=""
  local state_file=""

  while IFS= read -r dir; do
    state_file="$(ingress_qdisc_state_file_for_dir "$dir")"
    rm -f "$state_file" 2>/dev/null || true
  done < <(state_dir_candidates)
}

remove_wan_ingress_qdisc_if_owned() {
  local dev="$1"
  local qdisc_dump=""
  local filter_dump=""
  local ingress_dump=""
  local egress_dump=""

  if ! ingress_qdisc_is_owned "$dev"; then
    return 0
  fi

  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "WARN: Owned ingress qdisc interface '$dev' is unavailable; keeping marker for deterministic cleanup targeting." >&2
    return 0
  fi

  qdisc_dump="$(tc qdisc show dev "$dev" 2>/dev/null || true)"
  if ! grep -qE '^[[:space:]]*qdisc[[:space:]]+(ingress|clsact)([[:space:]]|$)' <<<"$qdisc_dump"; then
    clear_ingress_qdisc_state
    return 0
  fi

  filter_dump="$(tc filter show dev "$dev" 2>/dev/null || true)"
  if [[ -z "${filter_dump//[[:space:]]/}" ]]; then
    filter_dump="$(tc filter show dev "$dev" parent ffff: 2>/dev/null || true)"
  fi
  if [[ -z "${filter_dump//[[:space:]]/}" ]]; then
    ingress_dump="$(tc filter show dev "$dev" ingress 2>/dev/null || true)"
    egress_dump="$(tc filter show dev "$dev" egress 2>/dev/null || true)"
    if [[ -n "${ingress_dump//[[:space:]]/}" || -n "${egress_dump//[[:space:]]/}" ]]; then
      filter_dump="filters-present"
    fi
  fi
  if [[ -n "${filter_dump//[[:space:]]/}" ]]; then
    echo "ERROR: Ingress/clsact qdisc on '$dev' still has filters; owned qdisc delete is incomplete." >&2
    return 1
  fi

  if grep -qE '^[[:space:]]*qdisc[[:space:]]+clsact([[:space:]]|$)' <<<"$qdisc_dump"; then
    tc qdisc del dev "$dev" clsact 2>/dev/null || true
  else
    tc qdisc del dev "$dev" ingress 2>/dev/null || true
  fi

  qdisc_dump="$(tc qdisc show dev "$dev" 2>/dev/null || true)"
  if grep -qE '^[[:space:]]*qdisc[[:space:]]+(ingress|clsact)([[:space:]]|$)' <<<"$qdisc_dump"; then
    echo "ERROR: Failed to remove owned ingress/clsact qdisc on '$dev'." >&2
    return 1
  fi

  clear_ingress_qdisc_state
}

add_ingress_redirect_filters() {
  local wan="$1"
  local ifb="$2"

  if ! tc filter add dev "$wan" parent ffff: pref "$INGRESS_PREF" protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev "$ifb"; then
    echo "ERROR: Failed to install IPv4 ingress redirect filter on '$wan'." >&2
    return 1
  fi

  # Some minimal kernels may not support IPv6 filters; keep IPv4 path working.
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

release_global_lock() {
  (( GLOBAL_LOCK_HELD == 1 )) || return 0

  case "$GLOBAL_LOCK_KIND" in
    flock)
      flock -u 9 2>/dev/null || true
      exec 9>&- 2>/dev/null || true
      ;;
    pidfile)
      rm -f "$LOCK_PID_FILE" 2>/dev/null || true
      ;;
  esac

  GLOBAL_LOCK_HELD=0
  GLOBAL_LOCK_KIND="none"
}

acquire_global_lock_or_exit() {
  (( GLOBAL_LOCK_HELD == 1 )) && return 0
  local owner_pid=""

  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "ERROR: Failed to create state directory '$OFFLOAD_STATE_DIR'; cannot acquire global lock." >&2
    exit 1
  fi

  if command -v flock >/dev/null 2>&1; then
    if ! exec 9>"$LOCK_FILE"; then
      echo "ERROR: Failed to open lock file '$LOCK_FILE'." >&2
      exit 1
    fi
    if ! flock -n 9; then
      echo "ERROR: Another qos-cake operation is in progress; wait for it to finish and retry." >&2
      exit 1
    fi
    GLOBAL_LOCK_HELD=1
    GLOBAL_LOCK_KIND="flock"
    return 0
  fi

  if (set -o noclobber; printf '%s\n' "$$" >"$LOCK_PID_FILE") 2>/dev/null; then
    GLOBAL_LOCK_HELD=1
    GLOBAL_LOCK_KIND="pidfile"
    return 0
  fi

  owner_pid="$(awk 'NR==1 {print; exit}' "$LOCK_PID_FILE" 2>/dev/null || true)"
  owner_pid="${owner_pid%$'\r'}"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
    rm -f "$LOCK_PID_FILE" 2>/dev/null || true
    if (set -o noclobber; printf '%s\n' "$$" >"$LOCK_PID_FILE") 2>/dev/null; then
      GLOBAL_LOCK_HELD=1
      GLOBAL_LOCK_KIND="pidfile"
      return 0
    fi
  fi

  if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Another qos-cake operation is in progress (pid $owner_pid); wait for it to finish and retry." >&2
    exit 1
  fi

  echo "ERROR: Another qos-cake operation is in progress; wait for it to finish and retry." >&2
  exit 1
}

wan_if_state_file() {
  echo "${OFFLOAD_STATE_DIR%/}/wan-if.state"
}

load_named_state_from_candidates() {
  local state_name="$1"
  local out_value_var="$2"
  local out_file_var="$3"
  local dir=""
  local state_file=""
  local value=""

  while IFS= read -r dir; do
    state_file="${dir%/}/$state_name"
    [[ -r "$state_file" ]] || continue

    value="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    value="${value%$'\r'}"
    if [[ -z "$value" ]]; then
      rm -f "$state_file" 2>/dev/null || true
      continue
    fi

    printf -v "$out_value_var" '%s' "$value"
    printf -v "$out_file_var" '%s' "$state_file"
    return 0
  done < <(state_dir_candidates)

  printf -v "$out_value_var" ''
  printf -v "$out_file_var" ''
  return 1
}

migrate_named_state_to_primary_if_needed() {
  local source_file="$1"
  local target_file="$2"
  local value="$3"
  local tmp_file=""

  [[ -n "$source_file" && -n "$target_file" && -n "$value" ]] || return 0
  [[ "$source_file" == "$target_file" ]] && return 0

  if ! mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
    echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; keeping compatibility state file '$source_file'." >&2
    return 1
  fi

  tmp_file="${target_file}.tmp.$$"
  if printf '%s\n' "$value" >"$tmp_file" 2>/dev/null && \
    mv -f "$tmp_file" "$target_file" 2>/dev/null; then
    rm -f "$source_file" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  echo "WARN: Failed to migrate state from '$source_file' to '$target_file'; keeping compatibility state file." >&2
  return 1
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
  local selected_state_file=""
  local primary_state_file=""
  local dev=""

  if ! load_named_state_from_candidates "wan-if.state" dev selected_state_file; then
    return 1
  fi

  primary_state_file="$(wan_if_state_file)"
  migrate_named_state_to_primary_if_needed "$selected_state_file" "$primary_state_file" "$dev" || true

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
    detected="$(detect_wan_if || true)"
    if [[ -n "$detected" ]]; then
      echo "WARN: Pinned WAN_IF '$pinned' is unavailable; using detected WAN_IF '$detected'." >&2
      echo "$detected"
      return 0
    fi
    echo "$pinned"
    return 0
  fi

  if [[ -n "$root_owned" ]]; then
    if ip link show "$root_owned" >/dev/null 2>&1; then
      echo "$root_owned"
      return 0
    fi
    detected="$(detect_wan_if || true)"
    if [[ -n "$detected" ]]; then
      echo "WARN: Root-owned WAN_IF '$root_owned' is unavailable; using detected WAN_IF '$detected'." >&2
      echo "$detected"
      return 0
    fi
    echo "$root_owned"
    return 0
  fi

  detected="$(detect_wan_if || true)"
  [[ -n "$detected" ]] && echo "$detected"
}

clear_wan_if_state() {
  local entry=""
  local state_file=""
  local -a compat_dirs=()
  local -A seen=()

  entry="${OFFLOAD_STATE_DIR%/}"
  if [[ -n "$entry" ]]; then
    seen["$entry"]=1
    rm -f "${entry}/wan-if.state" 2>/dev/null || true
  fi

  if [[ -n "${OFFLOAD_STATE_COMPAT_DIRS//[[:space:]]/}" ]]; then
    IFS=':' read -r -a compat_dirs <<<"$OFFLOAD_STATE_COMPAT_DIRS"
    for entry in "${compat_dirs[@]}"; do
      entry="${entry%/}"
      [[ -z "$entry" || -n "${seen[$entry]+x}" ]] && continue
      seen["$entry"]=1
      state_file="${entry}/wan-if.state"
      rm -f "$state_file" 2>/dev/null || true
    done
  fi

  for entry in "$OFFLOAD_STATE_LEGACY_DIR" "/run/qos-cake" "/var/run/qos-cake"; do
    entry="${entry%/}"
    [[ -z "$entry" || -n "${seen[$entry]+x}" ]] && continue
    seen["$entry"]=1
    state_file="${entry}/wan-if.state"
    rm -f "$state_file" 2>/dev/null || true
  done
}

root_cake_state_file() {
  echo "${OFFLOAD_STATE_DIR%/}/root-cake.state"
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
  local selected_state_file=""
  local primary_state_file=""
  local dev=""

  if ! load_named_state_from_candidates "root-cake.state" dev selected_state_file; then
    return 1
  fi

  primary_state_file="$(root_cake_state_file)"
  migrate_named_state_to_primary_if_needed "$selected_state_file" "$primary_state_file" "$dev" || true

  if ! ip link show "$dev" >/dev/null 2>&1; then
    echo "WARN: Stored root-cake interface '$dev' is unavailable; keeping marker for deterministic cleanup targeting." >&2
  fi

  echo "$dev"
}

clear_root_cake_state() {
  local entry=""
  local state_file=""
  local -a compat_dirs=()
  local -A seen=()

  entry="${OFFLOAD_STATE_DIR%/}"
  if [[ -n "$entry" ]]; then
    seen["$entry"]=1
    rm -f "${entry}/root-cake.state" 2>/dev/null || true
  fi

  if [[ -n "${OFFLOAD_STATE_COMPAT_DIRS//[[:space:]]/}" ]]; then
    IFS=':' read -r -a compat_dirs <<<"$OFFLOAD_STATE_COMPAT_DIRS"
    for entry in "${compat_dirs[@]}"; do
      entry="${entry%/}"
      [[ -z "$entry" || -n "${seen[$entry]+x}" ]] && continue
      seen["$entry"]=1
      state_file="${entry}/root-cake.state"
      rm -f "$state_file" 2>/dev/null || true
    done
  fi

  for entry in "$OFFLOAD_STATE_LEGACY_DIR" "/run/qos-cake" "/var/run/qos-cake"; do
    entry="${entry%/}"
    [[ -z "$entry" || -n "${seen[$entry]+x}" ]] && continue
    seen["$entry"]=1
    state_file="${entry}/root-cake.state"
    rm -f "$state_file" 2>/dev/null || true
  done
}

find_compat_root_cake_state_file_for_dev() {
  local dev="$1"
  local allow_global_scan="${2:-$ALLOW_ROOT_STATE_GLOBAL_SCAN}"
  local dir=""
  local state_file=""
  local owner=""
  local wan_state_file=""
  local wan_state=""

  while IFS= read -r dir; do
    state_file="$dir/root-cake.state"
    [[ -r "$state_file" ]] || continue

    owner="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    owner="${owner%$'\r'}"
    if [[ "$owner" == "$dev" ]]; then
      wan_state_file="$dir/wan-if.state"
      if [[ -r "$wan_state_file" ]]; then
        wan_state="$(awk 'NR==1 {print; exit}' "$wan_state_file" 2>/dev/null || true)"
        wan_state="${wan_state%$'\r'}"
        if [[ -n "$wan_state" && "$wan_state" != "$dev" ]]; then
          continue
        fi
      fi
      echo "$state_file"
      return 0
    fi
  done < <(state_dir_candidates)

  case "${allow_global_scan,,}" in
    yes)
      ;;
    no)
      return 1
      ;;
    *)
      echo "WARN: Invalid ALLOW_ROOT_STATE_GLOBAL_SCAN='$allow_global_scan' (use yes/no); skipping global compatibility scan." >&2
      return 1
      ;;
  esac

  state_file="$(find_root_cake_state_file_for_dev_via_global_scan "$dev" || true)"
  if [[ -n "$state_file" ]]; then
    echo "$state_file"
    return 0
  fi

  return 1
}

find_root_cake_state_file_for_dev_via_global_scan() {
  local dev="$1"
  local state_file=""
  local dir=""
  local owner=""
  local wan_state_file=""
  local wan_state=""

  command -v find >/dev/null 2>&1 || return 1

  while IFS= read -r state_file; do
    [[ -r "$state_file" ]] || continue
    dir="${state_file%/*}"
    [[ -n "$dir" ]] || continue

    owner="$(awk 'NR==1 {print; exit}' "$state_file" 2>/dev/null || true)"
    owner="${owner%$'\r'}"
    [[ "$owner" == "$dev" ]] || continue

    wan_state_file="$dir/wan-if.state"
    if [[ -r "$wan_state_file" ]]; then
      wan_state="$(awk 'NR==1 {print; exit}' "$wan_state_file" 2>/dev/null || true)"
      wan_state="${wan_state%$'\r'}"
      if [[ -n "$wan_state" && "$wan_state" != "$dev" ]]; then
        continue
      fi
    fi

    echo "$state_file"
    return 0
  done < <(
    # Fallback scan for old custom state dirs after OFFLOAD_STATE_DIR changes.
    find / -maxdepth 8 \
      \( -path '/proc' -o -path '/proc/*' -o -path '/sys' -o -path '/sys/*' -o -path '/dev' -o -path '/dev/*' \) -prune -o \
      -type f -name 'root-cake.state' -print 2>/dev/null || true
  )

  return 1
}

root_cake_signature() {
  local dev="$1"
  local sig=""

  sig="$(tc qdisc show dev "$dev" 2>/dev/null | \
    awk '
      $1 == "qdisc" && $2 == "cake" {
        root_idx = 0
        out = ""
        for (i = 1; i <= NF; i++) {
          if ($i == "root") {
            root_idx = i
            break
          }
        }
        if (root_idx == 0) {
          next
        }
        for (i = root_idx + 1; i <= NF; i++) {
          if ($i == "refcnt" && (i + 1) <= NF && $(i + 1) ~ /^[0-9]+$/) {
            i++
            continue
          }
          out = out (out == "" ? "" : " ") $i
        }
        print out
        exit
      }
    ' || true)"

  echo "$sig"
}

ensure_preexisting_root_cake_unchanged_after_rollback() {
  local dev="$1"
  local had_root_cake_before="$2"
  local before_sig="$3"
  local after_sig=""

  (( had_root_cake_before == 1 )) || return 0

  after_sig="$(root_cake_signature "$dev")"
  if [[ -n "$before_sig" && -n "$after_sig" && "$after_sig" == "$before_sig" ]]; then
    return 0
  fi

  echo "WARN: '$dev' had pre-existing root CAKE; original CAKE parameters were not confirmed after rollback. Keeping state files for deterministic manual cleanup." >&2
  return 1
}

offload_state_file() {
  local dev="$1"
  offload_state_file_for_dir "$OFFLOAD_STATE_DIR" "$dev"
}

offload_state_file_for_dir() {
  local dir="$1"
  local dev="$2"
  local safe="$dev"

  safe="${safe//\//_}"
  safe="${safe//:/_}"
  dir="${dir%/}"

  echo "$dir/offload-${safe}.state"
}

list_existing_offload_state_files_for_dev() {
  local dev="$1"
  local dir=""
  local state_file=""

  while IFS= read -r dir; do
    state_file="$(offload_state_file_for_dir "$dir" "$dev")"
    [[ -r "$state_file" ]] || continue
    echo "$state_file"
  done < <(state_dir_candidates)
}

clear_all_offload_state_files_for_dev() {
  local dev="$1"
  local state_file=""

  while IFS= read -r state_file; do
    [[ -n "$state_file" ]] || continue
    rm -f "$state_file" 2>/dev/null || true
  done < <(list_existing_offload_state_files_for_dev "$dev")
}

capture_offload_state_if_needed() {
  local dev="$1"
  local state_file="$2"
  local candidate_state_file=""
  local tmp_file=""
  local tso=""
  local gso=""
  local gro=""

  while IFS= read -r candidate_state_file; do
    [[ -n "$candidate_state_file" ]] || continue

    tso="$(awk -F= '/^TSO=/{print $2; exit}' "$candidate_state_file" || true)"
    gso="$(awk -F= '/^GSO=/{print $2; exit}' "$candidate_state_file" || true)"
    gro="$(awk -F= '/^GRO=/{print $2; exit}' "$candidate_state_file" || true)"
    if [[ "$tso" =~ ^(on|off)$ && "$gso" =~ ^(on|off)$ && "$gro" =~ ^(on|off)$ ]]; then
      if [[ "$candidate_state_file" != "$state_file" ]]; then
        if mkdir -p "$OFFLOAD_STATE_DIR" 2>/dev/null; then
          tmp_file="${state_file}.tmp.$$"
          if printf 'TSO=%s\nGSO=%s\nGRO=%s\n' "$tso" "$gso" "$gro" >"$tmp_file" 2>/dev/null && \
            mv -f "$tmp_file" "$state_file" 2>/dev/null; then
            :
          else
            rm -f "$tmp_file" 2>/dev/null || true
            echo "WARN: Failed to migrate offload state from '$candidate_state_file' to '$state_file'; keeping compatibility state file." >&2
          fi
        else
          echo "WARN: Failed to create state directory '$OFFLOAD_STATE_DIR'; keeping compatibility offload state in '$candidate_state_file'." >&2
        fi
      fi
      return 0
    fi
    echo "WARN: Existing offload state file '$candidate_state_file' is invalid; recapturing." >&2
    rm -f "$candidate_state_file" 2>/dev/null || true
  done < <(list_existing_offload_state_files_for_dev "$dev")

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

  # Disable NIC offload before CAKE to avoid inaccurate shaping.
  if ! ethtool -K "$dev" tso off gso off gro off >/dev/null 2>&1; then
    echo "WARN: Failed to disable tso/gso/gro on '$dev'; shaping accuracy may degrade." >&2
  fi
}

restore_offload_if_needed() {
  local dev="$1"
  local state_file=""
  local first_state_file=""
  local tso=""
  local gso=""
  local gro=""
  local saw_state=0

  first_state_file="$(list_existing_offload_state_files_for_dev "$dev" | awk 'NR==1 {print; exit}')"
  [[ -n "$first_state_file" ]] || return 0

  if ! command -v ethtool >/dev/null 2>&1; then
    echo "WARN: ethtool not found; skipping offload restore on '$dev'." >&2
    return 0
  fi

  while IFS= read -r state_file; do
    [[ -n "$state_file" ]] || continue
    saw_state=1

    tso="$(awk -F= '/^TSO=/{print $2; exit}' "$state_file" || true)"
    gso="$(awk -F= '/^GSO=/{print $2; exit}' "$state_file" || true)"
    gro="$(awk -F= '/^GRO=/{print $2; exit}' "$state_file" || true)"

    if [[ ! "$tso" =~ ^(on|off)$ || ! "$gso" =~ ^(on|off)$ || ! "$gro" =~ ^(on|off)$ ]]; then
      echo "WARN: Invalid offload state in '$state_file'; skipping restore." >&2
      rm -f "$state_file" 2>/dev/null || true
      continue
    fi

    if ! ethtool -K "$dev" tso "$tso" gso "$gso" gro "$gro" >/dev/null 2>&1; then
      echo "WARN: Failed to restore tso/gso/gro on '$dev'; NIC may remain CPU-heavy." >&2
      return 1
    fi

    clear_all_offload_state_files_for_dev "$dev"
    return 0
  done < <(list_existing_offload_state_files_for_dev "$dev")

  (( saw_state == 0 )) && return 0
  echo "WARN: No valid offload state remained for '$dev'; NIC may remain CPU-heavy." >&2
  return 1
}

has_root_cake_qdisc() {
  local dev="$1"
  tc qdisc show dev "$dev" 2>/dev/null | awk '
    $1 == "qdisc" && $2 == "cake" {
      for (i = 1; i <= NF; i++) {
        if ($i == "root") {
          found = 1
          exit
        }
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  '
}

remove_wan_cake_root_if_owned() {
  local dev="$1"
  local owner=""
  local compat_owner_state_file=""
  local default_kind=""
  local post_kind=""

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
      [[ -n "$compat_owner_state_file" ]] && rm -f "$compat_owner_state_file" 2>/dev/null || true
    fi
    return 0
  fi

  if [[ -z "$owner" ]]; then
    compat_owner_state_file="$(find_compat_root_cake_state_file_for_dev "$dev" "$ALLOW_ROOT_STATE_GLOBAL_SCAN" || true)"
    if [[ -n "$compat_owner_state_file" ]]; then
      owner="$dev"
      echo "WARN: Root CAKE compatibility marker '$compat_owner_state_file' matches '$dev'; treating it as owned for cleanup." >&2
    fi
  fi

  if [[ -z "$owner" ]]; then
    default_kind="$(kernel_default_qdisc_kind)"
    if [[ "$default_kind" == "cake" ]]; then
      echo "INFO: Root CAKE on '$dev' is unowned but matches kernel default; leaving it untouched." >&2
      return 0
    fi

    case "${ALLOW_UNOWNED_WAN_CAKE_DELETE,,}" in
      yes)
        echo "WARN: Root CAKE on '$dev' has no ownership marker; deleting due to ALLOW_UNOWNED_WAN_CAKE_DELETE=yes." >&2
        ;;
      no)
        echo "ERROR: Root CAKE on '$dev' has no ownership marker; refusing to delete." >&2
        echo "ERROR: Set ALLOW_UNOWNED_WAN_CAKE_DELETE=yes to allow legacy/unowned cleanup." >&2
        echo "ERROR: If OFFLOAD_STATE_DIR was changed, set OFFLOAD_STATE_COMPAT_DIRS to old state dir(s) for migration-safe cleanup." >&2
        return 1
        ;;
      *)
        echo "ERROR: Invalid ALLOW_UNOWNED_WAN_CAKE_DELETE=$ALLOW_UNOWNED_WAN_CAKE_DELETE (use yes/no)." >&2
        return 1
        ;;
    esac
  fi

  if ! tc qdisc del dev "$dev" root 2>/dev/null; then
    echo "ERROR: Failed to remove CAKE root qdisc on '$dev'." >&2
    return 1
  fi

  post_kind="$(tc qdisc show dev "$dev" 2>/dev/null | awk '
    $1 == "qdisc" {
      kind = $2
      for (i = 1; i <= NF; i++) {
        if ($i == "root") {
          print kind
          exit
        }
      }
    }
  ' || true)"
  if [[ "$post_kind" == "cake" ]]; then
    default_kind="$(kernel_default_qdisc_kind)"
    if [[ "$default_kind" != "cake" ]]; then
      echo "ERROR: Failed to remove CAKE root qdisc on '$dev'." >&2
      return 1
    fi
    # default_qdisc=cake may re-attach a fresh default CAKE after deletion.
  fi

  clear_root_cake_state
  [[ -n "$compat_owner_state_file" ]] && rm -f "$compat_owner_state_file" 2>/dev/null || true
}

rollback_new_wan_cake_root_if_needed() {
  local dev="$1"
  local had_root_cake_before="$2"
  local before_sig="${3-}"
  local before_opts=()
  local current_sig=""
  local post_kind=""
  local default_kind=""

  if (( had_root_cake_before == 1 )); then
    current_sig="$(root_cake_signature "$dev")"
    if [[ -n "$before_sig" && -n "$current_sig" && "$current_sig" == "$before_sig" ]]; then
      return 0
    fi

    if [[ -z "$before_sig" ]]; then
      echo "WARN: Failed to roll back root CAKE on '$dev' to pre-existing parameters: original signature is unavailable." >&2
      return 1
    fi

    read -r -a before_opts <<<"$before_sig"
    if ! tc qdisc replace dev "$dev" root cake "${before_opts[@]}"; then
      echo "WARN: Failed to roll back root CAKE on '$dev' to pre-existing parameters." >&2
      return 1
    fi

    current_sig="$(root_cake_signature "$dev")"
    if [[ -n "$current_sig" && "$current_sig" == "$before_sig" ]]; then
      return 0
    fi

    echo "WARN: Root CAKE on '$dev' was not restored to pre-existing parameters." >&2
    return 1
  fi

  has_root_cake_qdisc "$dev" || return 0

  if ! tc qdisc del dev "$dev" root 2>/dev/null; then
    echo "WARN: Failed to roll back newly applied CAKE root qdisc on '$dev'." >&2
    return 1
  fi

  post_kind="$(tc qdisc show dev "$dev" 2>/dev/null | awk '
    $1 == "qdisc" {
      kind = $2
      for (i = 1; i <= NF; i++) {
        if ($i == "root") {
          print kind
          exit
        }
      }
    }
  ' || true)"
  if [[ "$post_kind" == "cake" ]]; then
    default_kind="$(kernel_default_qdisc_kind)"
    if [[ "$default_kind" != "cake" ]]; then
      echo "WARN: Failed to roll back newly applied CAKE root qdisc on '$dev'." >&2
      return 1
    fi
  fi

  return 0
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

  # NAT option
  case "$NAT" in
    yes)  opts+=(nat) ;;
    no)   : ;;
    auto) nf="$(nat_flag_auto)"; [[ -n "$nf" ]] && opts+=("$nf") ;;
    *)    echo "Invalid NAT=$NAT (use auto/yes/no)" >&2; return 1 ;;
  esac

  # Optional RTT
  [[ -n "$RTT" ]] && opts+=(rtt "$RTT")

  # Extra CAKE options (advanced usage)
  if [[ -n "$EXTRA_CAKE_OPTS" ]]; then
    local extra_arr=()
    read -r -a extra_arr <<< "$EXTRA_CAKE_OPTS"
    opts+=("${extra_arr[@]}")
  fi

  # Use replace for atomic add-or-update behavior.
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
  local was_up=0
  local root_kind=""
  local default_kind=""

  warn_virt_limits
  modprobe ifb 2>/dev/null || true

  if ip link show "$ifb" >/dev/null 2>&1; then
    if ! is_ifb_device "$ifb"; then
      echo "ERROR: Interface '$ifb' exists but is not an ifb device." >&2
      return 1
    fi
  else
    if ! ip link add "$ifb" type ifb; then
      echo "ERROR: Failed to create IFB device '$ifb'." >&2
      return 1
    fi
    created_new=1
  fi
  if ip -o link show dev "$ifb" 2>/dev/null | grep -qE '<([^>]*,)?UP(,|>)'; then
    was_up=1
  fi
  if ! ip link set "$ifb" up; then
    if (( created_new == 1 )); then
      ip link del "$ifb" 2>/dev/null || true
    fi
    echo "ERROR: Failed to bring IFB '$ifb' up." >&2
    return 1
  fi

  # If IFB was down and just brought up, clear kernel auto default qdisc.
  # This avoids false "in use" detection before this script can mark ownership.
  if (( was_up == 0 )) && ! ifb_is_marked_as_created "$ifb" && ! ifb_qdisc_is_owned "$ifb"; then
    root_kind="$(ifb_root_qdisc_kind "$ifb")"
    default_kind="$(kernel_default_qdisc_kind)"
    if (( created_new == 1 )) || [[ -n "$default_kind" && "$root_kind" == "$default_kind" ]]; then
      tc qdisc del dev "$ifb" root 2>/dev/null || true
    fi
  fi

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
  local qdisc_dump=""
  local created_qdisc_kind=""

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

  # Ensure ingress/clsact exists before managing redirect filters.
  qdisc_dump="$(tc qdisc show dev "$wan" 2>/dev/null || true)"
  if ! grep -qE '^[[:space:]]*qdisc[[:space:]]+(ingress|clsact)([[:space:]]|$)' <<<"$qdisc_dump"; then
    if tc qdisc add dev "$wan" handle ffff: ingress 2>/dev/null; then
      created_qdisc_kind="ingress"
    elif tc qdisc add dev "$wan" clsact; then
      created_qdisc_kind="clsact"
    else
      echo "ERROR: Failed to create ingress/clsact qdisc on '$wan'." >&2
      return 1
    fi
  fi

  # Clean script-managed filters at current pref, plus legacy prefs that still redirect to this IFB.
  if [[ -n "$created_qdisc_kind" ]]; then
    if ! save_ingress_qdisc_state "$wan"; then
      tc qdisc del dev "$wan" "$created_qdisc_kind" 2>/dev/null || true
      echo "ERROR: Failed to persist ingress qdisc ownership marker for '$wan'; rolling back ingress/clsact qdisc create." >&2
      return 1
    fi
  fi

  delete_ingress_redirect_filters "$wan" "$ifb"

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

  # Empty DOWN_BW means explicit ingress disable; clean residual state.
  if [[ -z "$DOWN_BW" ]]; then
    delete_ingress_redirect_filters "$wan" "$ifb"
    if has_script_ingress_redirect_filters "$wan" "$ifb"; then
      echo "ERROR: Ingress redirect filters on '$wan' remain after delete attempt." >&2
      return 1
    fi
    remove_wan_ingress_qdisc_if_owned "$wan" || return 1
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

  # Ingress shaping may also need nat when this host acts as NAT gateway.
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

  # Apply CAKE on IFB first, then attach redirect to avoid unshaped window.
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
  local had_root_cake_before=0
  local root_cake_signature_before=""

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

  if ! disable_offload_if_needed "$WAN_IF"; then
    echo "ERROR: Failed before applying egress; clearing pinned state." >&2
    clear_root_cake_state
    clear_wan_if_state
    exit 1
  fi
  if has_root_cake_qdisc "$WAN_IF"; then
    had_root_cake_before=1
    root_cake_signature_before="$(root_cake_signature "$WAN_IF")"
    if [[ -z "$root_cake_signature_before" ]]; then
      echo "WARN: Failed to snapshot pre-existing root CAKE signature on '$WAN_IF'; rollback will be conservative." >&2
    fi
  fi
  if ! apply_egress "$WAN_IF"; then
    echo "ERROR: Failed to apply egress CAKE; attempting rollback." >&2

    rollback_new_wan_cake_root_if_needed "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1
    restore_offload_if_needed "$WAN_IF" || rollback_failed=1
    ensure_preexisting_root_cake_unchanged_after_rollback "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1

    if (( rollback_failed == 0 )); then
      clear_wan_if_state
      clear_root_cake_state
    else
      echo "WARN: Rollback after egress failure was incomplete; keeping state files for deterministic manual cleanup." >&2
    fi
    exit 1
  fi
  if ! save_root_cake_state "$WAN_IF"; then
    echo "ERROR: Failed to persist root-cake ownership state after egress apply; attempting rollback." >&2

    rollback_new_wan_cake_root_if_needed "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1
    restore_offload_if_needed "$WAN_IF" || rollback_failed=1
    ensure_preexisting_root_cake_unchanged_after_rollback "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1

    if (( rollback_failed == 0 )); then
      clear_wan_if_state
      clear_root_cake_state
    else
      echo "WARN: Rollback after root-cake state persistence failure was incomplete; keeping state files for deterministic manual cleanup." >&2
    fi
    exit 1
  fi
  if ! apply_ingress_via_ifb "$WAN_IF" "$IFB_DEV"; then
    echo "ERROR: Failed to apply ingress shaping; attempting rollback." >&2

    # Best-effort rollback for partial start.
    delete_ingress_redirect_filters "$WAN_IF" "$IFB_DEV"
    if has_script_ingress_redirect_filters "$WAN_IF" "$IFB_DEV"; then
      echo "WARN: Ingress redirect filters on '$WAN_IF' remain after rollback delete attempt." >&2
      rollback_failed=1
    fi
    remove_wan_ingress_qdisc_if_owned "$WAN_IF" || rollback_failed=1
    if should_skip_unowned_ifb_cleanup "$IFB_DEV"; then
      echo "INFO: IFB '$IFB_DEV' root cake is unmarked; skipping IFB rollback cleanup." >&2
    else
      cleanup_ifb_qdisc_if_safe "$IFB_DEV" || rollback_failed=1
    fi
    rollback_new_wan_cake_root_if_needed "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1
    restore_offload_if_needed "$WAN_IF" || rollback_failed=1
    ensure_preexisting_root_cake_unchanged_after_rollback "$WAN_IF" "$had_root_cake_before" "$root_cake_signature_before" || rollback_failed=1

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
  local wan_cleanup_complete=0
  local ifb_cleanup_ok=1

  control_wan="$(resolve_control_wan_if "${WAN_IF-}" || true)"

  if [[ -n "$control_wan" ]]; then
    if ! ip link show "$control_wan" >/dev/null 2>&1; then
      echo "WARN: Resolved WAN interface '$control_wan' does not exist, skipping WAN qdisc cleanup." >&2
      stop_failed=1
    else
      wan_cleanup_confirmed=1
      wan_cleanup_complete=1
      if ! remove_wan_cake_root_if_owned "$control_wan"; then
        echo "WARN: Root CAKE ownership cleanup failed on '$control_wan'; continuing with remaining WAN cleanup." >&2
        stop_failed=1
        wan_cleanup_complete=0
      fi
      delete_ingress_redirect_filters "$control_wan" "$IFB_DEV"
      if ! remove_wan_ingress_qdisc_if_owned "$control_wan"; then
        stop_failed=1
        wan_cleanup_complete=0
      fi
      if has_script_ingress_redirect_filters "$control_wan" "$IFB_DEV"; then
        echo "WARN: Ingress redirect filters still exist on '$control_wan'; WAN cleanup is incomplete." >&2
        stop_failed=1
        wan_cleanup_complete=0
      fi
      restore_offload_if_needed "$control_wan" || stop_failed=1
    fi
  else
    echo "WARN: Cannot detect WAN interface, skipping WAN qdisc cleanup." >&2
    stop_failed=1
  fi

  # IFB cleanup: default is qdisc-only; device delete is opt-in.
  if (( wan_cleanup_confirmed == 1 && wan_cleanup_complete == 1 )); then
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
  elif (( wan_cleanup_confirmed == 1 )); then
    echo "WARN: Skipping IFB cleanup because WAN cleanup was incomplete." >&2
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

trap release_global_lock EXIT

case "$CMD" in
  start)
    acquire_global_lock_or_exit
    start
    ;;
  stop)
    acquire_global_lock_or_exit
    stop
    ;;
  restart)
    acquire_global_lock_or_exit
    restart_control_wan="$(resolve_control_wan_if "${WAN_IF-}" || true)"
    if [[ -z "${restart_control_wan-}" ]]; then
      echo "ERROR: Cannot determine restart control WAN_IF; aborting before stop." >&2
      exit 1
    fi
    restart_control_exists=0
    if ip link show "$restart_control_wan" >/dev/null 2>&1; then
      restart_control_exists=1
    fi
    if (( restart_control_exists == 0 )) && [[ -n "${WAN_IF-}" ]]; then
      echo "ERROR: Restart control WAN_IF '$restart_control_wan' does not exist; aborting before stop." >&2
      exit 1
    fi
    restart_start_wan="${WAN_IF-}"
    if [[ -z "${restart_start_wan-}" ]]; then
      if (( restart_control_exists == 1 )); then
        restart_start_wan="$restart_control_wan"
      else
        restart_start_wan="$(detect_wan_if || true)"
      fi
    fi
    if [[ -z "${restart_start_wan-}" ]]; then
      echo "ERROR: Cannot determine restart start WAN_IF; aborting before stop." >&2
      exit 1
    fi
    if ! ip link show "$restart_start_wan" >/dev/null 2>&1; then
      echo "ERROR: Restart start WAN_IF '$restart_start_wan' does not exist; aborting before stop." >&2
      exit 1
    fi
    restart_stop_failed=0
    if ! stop; then
      restart_stop_failed=1
      case "${RESTART_CONTINUE_ON_STOP_FAILURE,,}" in
        yes)
          echo "WARN: stop failed during restart; continuing because RESTART_CONTINUE_ON_STOP_FAILURE=yes." >&2
          ;;
        no)
          echo "ERROR: stop failed during restart; aborting before start to avoid partial-cleanup restart." >&2
          exit 2
          ;;
        *)
          echo "ERROR: Invalid RESTART_CONTINUE_ON_STOP_FAILURE=$RESTART_CONTINUE_ON_STOP_FAILURE (use yes/no)." >&2
          exit 1
          ;;
      esac
    fi
    WAN_IF="${restart_start_wan-}"
    start
    (( restart_stop_failed == 0 )) || exit 2
    ;;
  status)
    status
    ;;
  *) echo "Usage: $0 {start|stop|restart|status} [WAN_IF]" >&2; exit 1 ;;
esac
