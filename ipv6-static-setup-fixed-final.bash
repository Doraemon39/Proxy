#!/usr/bin/env bash
set -euo pipefail

umask 077

SERVICE="ipv6-static.service"
UNIT="/etc/systemd/system/${SERVICE}"
LIST="/etc/ipv6-static.list"
META="/etc/ipv6-static.meta"
BACKUP_DIR="/etc/ipv6-static.backup"
RESTORE_BIN="/usr/local/sbin/ipv6-static-restore"
MONITOR_SERVICE="ipv6-static-monitor.service"
MONITOR_UNIT="/etc/systemd/system/${MONITOR_SERVICE}"
MONITOR_SCRIPT="/usr/local/sbin/ipv6-static-monitor"
LEGACY_APPLY_SERVICE="ipv6-static-apply.service"
LEGACY_APPLY_UNIT="/etc/systemd/system/${LEGACY_APPLY_SERVICE}"
LEGACY_APPLY_TIMER="ipv6-static-apply.timer"
LEGACY_APPLY_TIMER_UNIT="/etc/systemd/system/${LEGACY_APPLY_TIMER}"

# ping 策略：0=失败只警告（避免 ICMP 被挡误回滚）；1=失败也回滚（更严格）
STRICT_PING=0

log(){ printf '%s\n' "$*"; }
warn(){ printf '⚠️ %s\n' "$*"; }
die(){ log "❌ $*"; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行（sudo -i 后再运行）"
have ip || die "缺少 ip（iproute2）"
have awk || die "缺少 awk"
have systemctl || die "缺少 systemctl（依赖 systemd）"
if ! have od && ! have hexdump; then
  die "缺少 od/hexdump（至少需要一个用于 /dev/urandom 随机数）"
fi

# ---------- 目标 home：尽量写到原始 sudo 用户家目录，而不是 /root ----------
TARGET_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  TH="$(eval echo "~$SUDO_USER" 2>/dev/null || true)"
  [ -d "${TH:-}" ] && TARGET_HOME="$TH"
fi
HOME_LIST="$TARGET_HOME/random-ipv6"

# -------------------- 回滚机制（失败不留残留） --------------------
ROLLBACK_NEEDED=0
BACKUP_DIR_CREATED=0
LATEST_PREEXIST=0
PREV_LATEST=""
BK=""
CHOSEN_IFACE=""
ASSIGN_PFXLEN=""
ASSIGN_OPTS=""

cleanup_added_ips() {
  local iface="$1"
  [ -z "${iface:-}" ] && return 0
  [ -f "$LIST" ] || return 0
  local pfx="${ASSIGN_PFXLEN:-128}"
  local opts="${ASSIGN_OPTS:-}"
  while read -r ip6; do
    [ -n "$ip6" ] || continue
    ip -6 addr del "$ip6/$pfx" dev "$iface" $opts 2>/dev/null || true
    ip -6 addr del "$ip6/128" dev "$iface" 2>/dev/null || true
    ip -6 addr del "$ip6/64" dev "$iface" 2>/dev/null || true
  done < "$LIST"
}

restore_backup_state() {
  if [ -f "$BK/old_unit" ]; then cp -f "$BK/old_unit" "$UNIT" || true; else rm -f "$UNIT" || true; fi
  if [ -f "$BK/old_list" ]; then cp -f "$BK/old_list" "$LIST" || true; else rm -f "$LIST" || true; fi
  if [ -f "$BK/old_meta" ]; then cp -f "$BK/old_meta" "$META" || true; else rm -f "$META" || true; fi
  if [ -f "$BK/old_restore_bin" ]; then cp -p -f "$BK/old_restore_bin" "$RESTORE_BIN" || true; else rm -f "$RESTORE_BIN" || true; fi
  if [ -f "$BK/old_monitor_unit" ]; then cp -f "$BK/old_monitor_unit" "$MONITOR_UNIT" || true; else rm -f "$MONITOR_UNIT" || true; fi
  if [ -f "$BK/old_monitor_script" ]; then cp -p -f "$BK/old_monitor_script" "$MONITOR_SCRIPT" || true; else rm -f "$MONITOR_SCRIPT" || true; fi
  if [ -f "$BK/old_apply_unit" ]; then cp -f "$BK/old_apply_unit" "$LEGACY_APPLY_UNIT" || true; else rm -f "$LEGACY_APPLY_UNIT" || true; fi
  if [ -f "$BK/old_apply_timer" ]; then cp -f "$BK/old_apply_timer" "$LEGACY_APPLY_TIMER_UNIT" || true; else rm -f "$LEGACY_APPLY_TIMER_UNIT" || true; fi

  # 恢复 home 文件：如果原本就存在，恢复备份；否则删掉新建的
  if [ -f "$BK/home_list_preexisted" ] && [ -f "$BK/old_home_list" ]; then
    cp -f "$BK/old_home_list" "$HOME_LIST" 2>/dev/null || true
  elif [ -f "$BK/home_list_created" ]; then
    rm -f "$HOME_LIST" 2>/dev/null || true
  fi

  if [ "$LATEST_PREEXIST" -eq 1 ]; then
    printf '%s' "$PREV_LATEST" > "$BACKUP_DIR/latest" 2>/dev/null || true
  else
    rm -f "$BACKUP_DIR/latest" 2>/dev/null || true
  fi

  rm -rf "$BK" 2>/dev/null || true
  if [ "$BACKUP_DIR_CREATED" -eq 1 ]; then
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
  fi
}

rollback() {
  [ "$ROLLBACK_NEEDED" -eq 1 ] || return 0

  # 先读取旧状态：restore_backup_state 会删除 $BK 目录，不能在之后再读。
  local was_enabled=0
  local monitor_enabled=0
  local legacy_apply_timer_enabled=0
  local legacy_apply_service_enabled=0
  if [ -n "${BK:-}" ] && [ -f "$BK/was_enabled" ] && grep -qx "enabled" "$BK/was_enabled"; then
    was_enabled=1
  fi
  if [ -n "${BK:-}" ] && [ -f "$BK/was_monitor_enabled" ] && grep -qx "enabled" "$BK/was_monitor_enabled"; then
    monitor_enabled=1
  fi
  if [ -n "${BK:-}" ] && [ -f "$BK/was_legacy_apply_timer_enabled" ] && grep -qx "enabled" "$BK/was_legacy_apply_timer_enabled"; then
    legacy_apply_timer_enabled=1
  fi
  if [ -n "${BK:-}" ] && [ -f "$BK/was_legacy_apply_service_enabled" ] && grep -qx "enabled" "$BK/was_legacy_apply_service_enabled"; then
    legacy_apply_service_enabled=1
  fi

  warn "发生错误，开始回滚（恢复运行前状态，尽量不留残留）..."
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true

  if [ -n "${CHOSEN_IFACE:-}" ]; then
    cleanup_added_ips "$CHOSEN_IFACE"
  fi

  restore_backup_state
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ "$was_enabled" -eq 1 ]; then
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
  fi
  if [ "$monitor_enabled" -eq 1 ]; then
    systemctl enable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
  fi
  if [ "$legacy_apply_timer_enabled" -eq 1 ]; then
    systemctl enable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  fi
  if [ "$legacy_apply_service_enabled" -eq 1 ]; then
    systemctl enable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true
  fi

  warn "回滚完成。"
}

# -------------------- 失败闭环：即使尚未开始改系统，也不留下备份残留 --------------------
early_cleanup_backup() {
  # 仅清理“本次运行新建的备份快照”，不碰已有配置文件
  if [ -n "${BK:-}" ] && [ -d "$BK" ]; then
    if [ "$LATEST_PREEXIST" -eq 1 ]; then
      printf '%s' "$PREV_LATEST" > "$BACKUP_DIR/latest" 2>/dev/null || true
    else
      rm -f "$BACKUP_DIR/latest" 2>/dev/null || true
    fi
    rm -rf "$BK" 2>/dev/null || true
  fi

  # 如果本次运行才创建 BACKUP_DIR，则失败时一并清理
  if [ "$BACKUP_DIR_CREATED" -eq 1 ]; then
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
  fi
}

on_exit() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0

  if [ "$ROLLBACK_NEEDED" -eq 1 ]; then
    rollback
  else
    warn "发生错误（退出码 $rc），尚未开始修改系统配置，清理本次备份残留..."
    early_cleanup_backup
  fi
}

trap on_exit EXIT

# -------------------- 备份准备（失败也能完全恢复） --------------------
if [ ! -d "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true
  BACKUP_DIR_CREATED=1
fi

if [ -f "$BACKUP_DIR/latest" ]; then
  LATEST_PREEXIST=1
  PREV_LATEST="$(cat "$BACKUP_DIR/latest" 2>/dev/null || true)"
fi

TS_BASE="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "unknown_time")"
TS_NS="$(date +%N 2>/dev/null || true)"
case "$TS_NS" in (""|*[!0-9]*) TS_NS="$RANDOM" ;; esac
TS_RAND="$(printf %04x "$RANDOM")"
TS="${TS_BASE}_${TS_NS}_${TS_RAND}"
BK="$BACKUP_DIR/$TS"
mkdir -p "$BK"
printf '%s' "$TS" > "$BACKUP_DIR/latest"

[ -f "$UNIT" ] && cp -f "$UNIT" "$BK/old_unit"
[ -f "$LIST" ] && cp -f "$LIST" "$BK/old_list"
[ -f "$META" ] && cp -f "$META" "$BK/old_meta"
[ -f "$RESTORE_BIN" ] && cp -p -f "$RESTORE_BIN" "$BK/old_restore_bin"
[ -f "$MONITOR_UNIT" ] && cp -f "$MONITOR_UNIT" "$BK/old_monitor_unit"
[ -f "$MONITOR_SCRIPT" ] && cp -p -f "$MONITOR_SCRIPT" "$BK/old_monitor_script"
[ -f "$LEGACY_APPLY_UNIT" ] && cp -f "$LEGACY_APPLY_UNIT" "$BK/old_apply_unit"
[ -f "$LEGACY_APPLY_TIMER_UNIT" ] && cp -f "$LEGACY_APPLY_TIMER_UNIT" "$BK/old_apply_timer"
if systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then echo "enabled" > "$BK/was_enabled"; else echo "disabled" > "$BK/was_enabled"; fi
if systemctl is-enabled "$MONITOR_SERVICE" >/dev/null 2>&1; then echo "enabled" > "$BK/was_monitor_enabled"; else echo "disabled" > "$BK/was_monitor_enabled"; fi
if systemctl is-enabled "$LEGACY_APPLY_TIMER" >/dev/null 2>&1; then echo "enabled" > "$BK/was_legacy_apply_timer_enabled"; else echo "disabled" > "$BK/was_legacy_apply_timer_enabled"; fi
if systemctl is-enabled "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1; then echo "enabled" > "$BK/was_legacy_apply_service_enabled"; else echo "disabled" > "$BK/was_legacy_apply_service_enabled"; fi

# 备份/标记 home 文件
if [ -e "$HOME_LIST" ]; then
  echo "1" > "$BK/home_list_preexisted"
  cp -f "$HOME_LIST" "$BK/old_home_list" 2>/dev/null || true
else
  echo "1" > "$BK/home_list_created"
fi

# -------------------- 探测网卡（多级回退） --------------------
detect_iface() {
  local iface=""
  iface="$(ip -6 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }
  iface="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }
  while read -r dev; do
    [ "$dev" = "lo" ] && continue
    ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{found=1; exit} END{exit !found}' && { echo "$dev"; return 0; }
  done < <(ip -o link show up 2>/dev/null | awk -F': ' '{split($2,a,"@"); print a[1]}')
  return 1
}

IFACE="$(detect_iface || true)"
[ -n "${IFACE:-}" ] || die "无法探测到合适网卡（无默认 IPv6 路由且扫描不到 global IPv6）"
CHOSEN_IFACE="$IFACE"
log "✅ 网卡: $IFACE"

# -------------------- 探测 IPv6 与可用前缀（多级回退） --------------------
pick_global_cidr() {
  local iface="$1" cidr=""
  cidr="$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '!/ temporary / && !/deprecated/ {print $4; exit}')"
  [ -n "${cidr:-}" ] && { echo "$cidr"; return 0; }
  cidr="$(ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')"
  [ -n "${cidr:-}" ] && { echo "$cidr"; return 0; }
  cidr="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "${cidr:-}" ] && { echo "${cidr}/128"; return 0; }
  return 1
}

pick_connected_prefix() {
  local iface="$1"
  ip -6 route show dev "$iface" proto kernel 2>/dev/null \
    | awk '{p=$1; if(p ~ /^fe80:/) next; n=split(p,a,"/"); if(n==2){len=a[2]+0; if(len>0 && len<128){print p; exit}}}'
}

CIDR="$(pick_global_cidr "$IFACE" || true)"
[ -n "${CIDR:-}" ] || die "网卡 $IFACE 上找不到 global IPv6"
CURRENT_IP="${CIDR%/*}"
PFXLEN_ADDR="${CIDR#*/}"

ROUTE_PFX="$(pick_connected_prefix "$IFACE" || true)"
BASE_IP="$CURRENT_IP"
GEN_PFXLEN="$PFXLEN_ADDR"
if [ -n "${ROUTE_PFX:-}" ]; then
  RP_IP="${ROUTE_PFX%/*}"
  RP_LEN="${ROUTE_PFX#*/}"
  if [ "$RP_LEN" -gt 0 ] && [ "$RP_LEN" -lt 128 ]; then
    BASE_IP="$RP_IP"
    GEN_PFXLEN="$RP_LEN"
  fi
fi

[ "$GEN_PFXLEN" -lt 128 ] || die "检测到前缀 /$GEN_PFXLEN（通常是单地址路由），不适合生成多个 IPv6。请确认是否提供 /64。"

if [ "$GEN_PFXLEN" -lt 64 ]; then
  warn "检测到前缀 /$GEN_PFXLEN（< /64），为兼容性仅在当前 /64 内生成。"
  GEN_PFXLEN=64
  BASE_IP="$CURRENT_IP"
fi

log "✅ 主IPv6: $CURRENT_IP/$PFXLEN_ADDR"
log "✅ 生成前缀: $BASE_IP/$GEN_PFXLEN"

# -------------------- IPv6 展开/归一化（解决 :: 压缩导致的误判） --------------------
expand_ipv6() {
  local ip="${1%%/*}"
  local left right
  local -a L R FULL
  if [[ "$ip" == *"::"* ]]; then
    left="${ip%%::*}"
    right="${ip##*::}"
    IFS=':' read -r -a L <<< "${left:-}"
    IFS=':' read -r -a R <<< "${right:-}"
    local lcount=0 rcount=0
    [ -n "${left:-}" ] && lcount="${#L[@]}"
    [ -n "${right:-}" ] && rcount="${#R[@]}"
    local missing=$((8 - lcount - rcount))
    FULL=()
    [ "$lcount" -gt 0 ] && FULL+=("${L[@]}")
    for ((i=0;i<missing;i++)); do FULL+=("0"); done
    [ "$rcount" -gt 0 ] && FULL+=("${R[@]}")
  else
    IFS=':' read -r -a FULL <<< "$ip"
  fi
  for ((i=0;i<8;i++)); do
    local h="${FULL[i]:-0}"
    if ! [[ "$h" =~ ^[0-9A-Fa-f]{1,4}$ ]]; then
      return 1
    fi
    printf "%04x" "$((16#$h))"
    ((i<7)) && printf ":"
  done
}

norm6() { expand_ipv6 "$1" 2>/dev/null | tr -d ':' || true; }

in_prefix_norm() {
  local ip_norm="$1" base_norm="$2" plen="$3"
  local full=$((plen/4))
  local rem=$((plen%4))
  [[ "${ip_norm:0:full}" = "${base_norm:0:full}" ]] || return 1
  if (( rem > 0 )); then
    local ip_nib="${ip_norm:full:1}"
    local base_nib="${base_norm:full:1}"
    local mask=$(( (0xF << (4-rem)) & 0xF ))
    (( (0x$ip_nib & mask) == (0x$base_nib & mask) )) || return 1
  fi
  return 0
}

addr_line_by_norm() {
  local cand="$1"
  local candn; candn="$(norm6 "$cand")"
  local found=""
  while IFS= read -r line; do
    # -o 输出里，第4列是 addr/prefix
    local ap; ap="$(awk '{print $4}' <<<"$line")"
    local aip="${ap%/*}"
    if [ "$(norm6 "$aip")" = "$candn" ]; then
      found="$line"; break
    fi
  done < <(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null || true)
  [ -n "$found" ] && { echo "$found"; return 0; }
  return 1
}

rand16_hex() {
  local val=""
  if have od; then
    val="$(od -An -N2 -tx2 /dev/urandom 2>/dev/null | tr -d ' \n\r' || true)"
  elif have hexdump; then
    val="$(hexdump -n 2 -e '1/2 "%04x"' /dev/urandom 2>/dev/null || true)"
  fi

  val="$(printf '%s' "$val" | tr -cd '0-9a-fA-F' | cut -c1-4)"
  if [ -z "$val" ]; then
    printf "%04x" "$RANDOM"
  else
    printf '%s' "$val"
  fi
}

BASE_EXP="$(expand_ipv6 "$BASE_IP" || true)"
[ -n "$BASE_EXP" ] || die "IPv6 expansion failed: BASE_IP may contain invalid characters"
BASE_NORM="${BASE_EXP//:/}"
IFS=':' read -r -a BASE_ARR <<< "$BASE_EXP" || true
[ "${#BASE_ARR[@]}" -eq 8 ] || die "IPv6 expansion unexpected: BASE_IP -> $BASE_EXP"

gen_one_ip() {
  local plen="$GEN_PFXLEN"
  local -a OUT=()
  for ((i=0;i<8;i++)); do
    local rhex="$(rand16_hex)"
    local r=$((16#$rhex))
    local p=$((16#${BASE_ARR[i]}))
    if (( plen >= 16 )); then
      OUT[i]="$p"; plen=$((plen-16))
    elif (( plen > 0 )); then
      local keep="$plen"
      local mask=$(( (0xFFFF << (16-keep)) & 0xFFFF ))
      OUT[i]=$(( (p & mask) | (r & (~mask & 0xFFFF)) ))
      plen=0
    else
      OUT[i]="$r"
    fi
  done
  for ((i=0;i<8;i++)); do printf "%x" "${OUT[i]}"; ((i<7)) && printf ":"; done
  return 0
}

pick_probe_ip() {
  local i ip6
  for ((i=1; i<=40; i++)); do
    ip6="$(gen_one_ip)" || continue
    [ -n "${ip6:-}" ] || continue
    grep -qx "$ip6" "$LIST" 2>/dev/null && continue
    if addr_line_by_norm "$ip6" >/dev/null 2>&1; then
      continue
    fi
    echo "$ip6"; return 0
  done
  return 1
}

# -------------------- 生成 5 个地址（优先读取旧列表） --------------------
ROLLBACK_NEEDED=1
existing_ips=()
existing_norms=()
if [ -f "$LIST" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line%%[[:space:]]*}"
    [ -n "$line" ] || continue
    norm_line="$(norm6 "$line")"
    [ -n "$norm_line" ] || continue
    if [ -n "${BASE_NORM:-}" ] && [ -n "${GEN_PFXLEN:-}" ] && [ "$GEN_PFXLEN" -gt 0 ]; then
      in_prefix_norm "$norm_line" "$BASE_NORM" "$GEN_PFXLEN" || continue
    fi
    dup=0
    for ipn in "${existing_norms[@]}"; do
      [ "$ipn" = "$norm_line" ] && { dup=1; break; }
    done
    if [ "$dup" -eq 0 ]; then
      existing_norms+=("$norm_line")
      existing_ips+=("$line")
    fi
  done < "$LIST"
fi

: > "$LIST"
chmod 600 "$LIST" || true
count=0
if [ "${#existing_ips[@]}" -gt 0 ]; then
  if [ "${#existing_ips[@]}" -ge 5 ]; then
    warn "existing list has >=5 addresses; using first 5"
  else
    warn "existing list has ${#existing_ips[@]} addresses; generating more"
  fi
  for ip6 in "${existing_ips[@]}"; do
    echo "$ip6" >> "$LIST"
    count=$((count+1))
    [ "$count" -ge 5 ] && break
  done
fi
while [ "$count" -lt 5 ]; do
  if ! ip6="$(gen_one_ip)"; then
    die "IPv6 generation failed (random or prefix parsing issue)"
  fi
  [ -n "$ip6" ] || die "IPv6 generation failed (empty result)"
  if grep -qx "$ip6" "$LIST" 2>/dev/null; then
    continue
  fi
  echo "$ip6" >> "$LIST"
  count=$((count+1))
done

# -------------------- 选择添加方式（回退） --------------------
try_add_del() {
  local ip6="$1" pfx="$2"; shift 2
  local -a opts=()
  local _opt
  for _opt in "$@"; do
    [ -n "${_opt}" ] && opts+=("${_opt}")
  done
  if ip -6 addr add "$ip6/$pfx" dev "$IFACE" "${opts[@]}" 2>/dev/null; then
    ip -6 addr del "$ip6/$pfx" dev "$IFACE" "${opts[@]}" 2>/dev/null || true
    return 0
  fi
  return 1
}

first_ip="$(head -n1 "$LIST")"
# 作为“探测添加方式”的探针 IP：如果 first_ip 已经存在于网卡上（脚本二次运行很常见），
# 则临时生成一个不冲突的地址来测试添加/删除能力（不写入 LIST、不持久化）。
probe_ip="$first_ip"
if addr_line_by_norm "$probe_ip" >/dev/null 2>&1; then
  for (( _i=0; _i<50; _i++ )); do
    cand="$(gen_one_ip)" || break
    [ -n "$cand" ] || continue
    grep -qx "$cand" "$LIST" 2>/dev/null && continue
    if ! addr_line_by_norm "$cand" >/dev/null 2>&1; then
      probe_ip="$cand"
      break
    fi
  done
fi
if try_add_del "$probe_ip" 128 "noprefixroute"; then
  ASSIGN_PFXLEN=128; ASSIGN_OPTS="noprefixroute"
elif try_add_del "$probe_ip" 128; then
  ASSIGN_PFXLEN=128; ASSIGN_OPTS=""
elif try_add_del "$probe_ip" "$GEN_PFXLEN"; then
  ASSIGN_PFXLEN="$GEN_PFXLEN"; ASSIGN_OPTS=""
elif try_add_del "$probe_ip" "$GEN_PFXLEN" "noprefixroute"; then
  ASSIGN_PFXLEN="$GEN_PFXLEN"; ASSIGN_OPTS="noprefixroute"
else
  die "多种方式仍无法添加 IPv6（可能服务商禁用额外 IPv6 或需要额外网络设置）"
fi
log "✅ 添加方式：/$ASSIGN_PFXLEN ${ASSIGN_OPTS:-"(no extra opts)"}"

# -------------------- 写 unit 并启动 --------------------
systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
systemctl disable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
systemctl disable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
systemctl disable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true

IP_BIN="$(command -v ip 2>/dev/null || true)"
[ -n "$IP_BIN" ] || IP_BIN="/usr/sbin/ip"
[ -x "$IP_BIN" ] || IP_BIN="/sbin/ip"
[ -x "$IP_BIN" ] || die "ip command not found (iproute2)"

cat > "$UNIT" <<EOF
[Unit]
Description=Add 5 Static IPv6 Addresses (generated once, persistent)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
EOF

while read -r ip6; do
  [ -n "$ip6" ] || continue
  if [ -n "$ASSIGN_OPTS" ]; then
    printf 'ExecStart=-%s -6 addr add %s/%s dev %s %s\n' "$IP_BIN" "$ip6" "$ASSIGN_PFXLEN" "$IFACE" "$ASSIGN_OPTS" >> "$UNIT"
  else
    printf 'ExecStart=-%s -6 addr add %s/%s dev %s\n' "$IP_BIN" "$ip6" "$ASSIGN_PFXLEN" "$IFACE" >> "$UNIT"
  fi
done < "$LIST"

while read -r ip6; do
  [ -n "$ip6" ] || continue
  if [ -n "$ASSIGN_OPTS" ]; then
    printf 'ExecStop=-%s -6 addr del %s/%s dev %s %s\n' "$IP_BIN" "$ip6" "$ASSIGN_PFXLEN" "$IFACE" "$ASSIGN_OPTS" >> "$UNIT"
  else
    printf 'ExecStop=-%s -6 addr del %s/%s dev %s\n' "$IP_BIN" "$ip6" "$ASSIGN_PFXLEN" "$IFACE" >> "$UNIT"
  fi
done < "$LIST"

cat >> "$UNIT" <<EOF

[Install]
WantedBy=multi-user.target
EOF

cat > "$MONITOR_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# === 运行时注入的常量 ===
IP_CMD="$IP_BIN"
IFACE="$IFACE"
ASSIGN_PFXLEN="$ASSIGN_PFXLEN"
ASSIGN_OPTS="$ASSIGN_OPTS"
LIST_PATH="$LIST"

# === 轻量锁 + 脏标记（去抖） ===
LOCK_FILE="/run/ipv6-static-monitor.lock"
LOCK_DIR="/run/ipv6-static-monitor.lockdir"
DIRTY_FILE="/run/ipv6-static-monitor.dirty"
HAVE_FLOCK=1
if ! command -v flock >/dev/null 2>&1; then
  HAVE_FLOCK=0
fi

do_add_ips() {
  [ -f "\$LIST_PATH" ] || return 0
  while IFS= read -r line; do
    line="\${line%%#*}"
    line="\${line%%[[:space:]]*}"
    [ -n "\$line" ] || continue
    
    if [ -n "\$ASSIGN_OPTS" ]; then
      "\$IP_CMD" -6 addr add "\$line/\$ASSIGN_PFXLEN" dev "\$IFACE" \$ASSIGN_OPTS 2>/dev/null || true
    else
      "\$IP_CMD" -6 addr add "\$line/\$ASSIGN_PFXLEN" dev "\$IFACE" 2>/dev/null || true
    fi
  done < "\$LIST_PATH"
}

do_sync_body() {
  rm -f "\$DIRTY_FILE"
  while true; do
    do_add_ips
    if [ -f "\$DIRTY_FILE" ]; then
      rm -f "\$DIRTY_FILE"
      sleep 1
    else
      break
    fi
  done
}

run_sync() {
  if [ "\$HAVE_FLOCK" -eq 1 ]; then
    (
      # 已有实例持锁时，标记脏后交给持锁方再次补齐
      flock -n 9 || { touch "\$DIRTY_FILE"; exit 0; }

      # 进入临界区后先清理脏标记
      do_sync_body
    ) 9>"\$LOCK_FILE"
    return 0
  fi

  # 无 flock 时的简单 lockdir 回退，带轻量 stale 处理
  local pidfile="\$LOCK_DIR/pid"
  if mkdir "\$LOCK_DIR" 2>/dev/null; then
    echo "\$\$" > "\$pidfile" 2>/dev/null || true
    do_sync_body
    rm -rf "\$LOCK_DIR" 2>/dev/null || true
    return 0
  fi

  if [ -f "\$pidfile" ]; then
    local opid
    opid="\$(cat "\$pidfile" 2>/dev/null || true)"
    if [ -n "\$opid" ] && kill -0 "\$opid" 2>/dev/null; then
      touch "\$DIRTY_FILE"
      return 0
    fi
  fi

  rm -rf "\$LOCK_DIR" 2>/dev/null || true
  if mkdir "\$LOCK_DIR" 2>/dev/null; then
    echo "\$\$" > "\$pidfile" 2>/dev/null || true
    do_sync_body
    rm -rf "\$LOCK_DIR" 2>/dev/null || true
  else
    touch "\$DIRTY_FILE"
  fi
}

trigger_sync() {
  ( sleep 1; run_sync ) >/dev/null 2>&1 &
}

# 启动后先补齐一次
trigger_sync

while true; do
  ("\$IP_CMD" -6 monitor address dev "\$IFACE" 2>/dev/null || true) | while read -r _line; do
    case "\${_line}" in
      *Deleted*|*RTM_DELADDR* )
        trigger_sync
        ;;
    esac
  done
  
  sleep 2
done
EOF
chmod +x "$MONITOR_SCRIPT"

cat > "$MONITOR_UNIT" <<EOF
[Unit]
Description=IPv6 Static Address Monitor (event-driven)
Wants=network-online.target
After=network-online.target
After=$SERVICE
PartOf=$SERVICE
ConditionPathExists=/sys/class/net/$IFACE

[Service]
Type=simple
ExecStart=$MONITOR_SCRIPT
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"
systemctl enable --now "$MONITOR_SERVICE"

# -------------------- 绑定验证（用归一化避免 :: 压缩误判） --------------------
verify_count() {
  local n=0
  while read -r ip6; do
    [ -n "$ip6" ] || continue
    if addr_line_by_norm "$ip6" >/dev/null 2>&1; then
      n=$((n+1))
    fi
  done < "$LIST"
  echo "$n"
}
added="$(verify_count)"
[ "$added" -eq 5 ] || die "验证失败：仅成功添加 $added/5 个 IPv6（将回滚）"

# -------------------- 安全校验：DAD + route-get +（可选）ping --------------------
wait_dad_ok() {
  local ip6="$1"
  local deadline=$((SECONDS+20))
  while [ $SECONDS -lt $deadline ]; do
    local line=""
    line="$(addr_line_by_norm "$ip6" 2>/dev/null || true)"
    [ -n "$line" ] || return 1
    echo "$line" | grep -qw dadfailed && return 2
    echo "$line" | grep -qw tentative && { sleep 1; continue; }
    return 0
  done
  return 3
}

route_check() { ip -6 route get 2606:4700:4700::1111 from "$1" >/dev/null 2>&1; }
ping_check() { have ping && ping -6 -c 2 -I "$1" 2606:4700:4700::1111 >/dev/null 2>&1; }

log "🔎 安全校验：DAD + route-get..."
route_check_warned=0
while read -r ip6; do
  [ -n "$ip6" ] || continue
  wait_dad_ok "$ip6" || {
    rc=$?
    case "$rc" in
      1) die "DAD 失败：$ip6 未出现在地址列表（异常）" ;;
      2) die "DAD 失败：$ip6 dadfailed（冲突/重复）" ;;
      3) die "DAD 超时：$ip6 长时间 tentative" ;;
      *) die "DAD 失败：$ip6（未知原因）" ;;
    esac
  }
  if ! route_check "$ip6"; then
    warn "route-get 失败：源地址 $ip6 无法选择有效路由（仅警告，未回滚）"
    route_check_warned=1
  fi
done < "$LIST"
if [ "$route_check_warned" -eq 0 ]; then
  log "✅ DAD + route-get 通过"
else
  warn "route-get 存在失败（可能网络阻断或无公网路由），已保留地址"
fi

log "🔎 可选校验：最小 ICMP 出站（失败可能是 ICMP 被挡）"
while read -r ip6; do
  [ -n "$ip6" ] || continue
  if ping_check "$ip6"; then
    log "  ✅ ping from $ip6 OK"
  else
    if ! have ping; then
      warn "未安装 ping（iputils-ping），跳过 ICMP 测试"
      break
    fi
    msg="ping from $ip6 失败（可能 ICMPv6 被屏蔽，或源地址出站不可用）"
    if [ "$STRICT_PING" -eq 1 ]; then
      die "$msg（STRICT_PING=1）"
    else
      warn "$msg（不回滚，仅提示）"
    fi
  fi
done < "$LIST"

# -------------------- 写 meta + 写还原脚本（卸载无残留） --------------------
cat > "$META" <<EOF
timestamp=$TS
iface_detected=$IFACE
current_cidr=$CIDR
base_ip_for_generation=$BASE_IP
gen_prefixlen=$GEN_PFXLEN
assign_prefixlen=$ASSIGN_PFXLEN
assign_opts=$ASSIGN_OPTS
list_path=$LIST
unit_path=$UNIT
backup_dir=$BK
home_list_path=$HOME_LIST
home_list_preexisted=$( [ -f "$BK/home_list_preexisted" ] && echo 1 || echo 0 )
EOF
chmod 600 "$META" || true

cat > "$RESTORE_BIN" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

umask 077

SERVICE="ipv6-static.service"
UNIT="/etc/systemd/system/${SERVICE}"
LIST="/etc/ipv6-static.list"
META="/etc/ipv6-static.meta"
BACKUP_DIR="/etc/ipv6-static.backup"
MONITOR_SERVICE="ipv6-static-monitor.service"
MONITOR_UNIT="/etc/systemd/system/${MONITOR_SERVICE}"
MONITOR_SCRIPT="/usr/local/sbin/ipv6-static-monitor"
LEGACY_APPLY_SERVICE="ipv6-static-apply.service"
LEGACY_APPLY_UNIT="/etc/systemd/system/${LEGACY_APPLY_SERVICE}"
LEGACY_APPLY_TIMER="ipv6-static-apply.timer"
LEGACY_APPLY_TIMER_UNIT="/etc/systemd/system/${LEGACY_APPLY_TIMER}"

log(){ printf '%s\n' "$*"; }
die(){ log "❌ $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行"
MODE="${1:---uninstall}"

detect_iface() {
  local iface=""
  iface="$(ip -6 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }
  iface="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  [ -n "${iface:-}" ] && { echo "$iface"; return 0; }
  while read -r dev; do
    [ "$dev" = "lo" ] && continue
    ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{found=1; exit} END{exit !found}' && { echo "$dev"; return 0; }
  done < <(ip -o link show up 2>/dev/null | awk -F': ' '{split($2,a,"@"); print a[1]}')
  return 1
}

read_meta() {
  ASSIGN_PFXLEN="128"
  ASSIGN_OPTS=""
  HOME_LIST_PATH=""
  BK=""
  HOME_LIST_PREEXISTED=0
  IFACE_META=""
  if [ -f "$META" ]; then
    while IFS='=' read -r k v; do
      [ -n "${k:-}" ] || continue
      k="${k%%[[:space:]]*}"
      case "$k" in
        assign_prefixlen) ASSIGN_PFXLEN="$v" ;;
        assign_opts) ASSIGN_OPTS="$v" ;;
        home_list_path) HOME_LIST_PATH="$v" ;;
        backup_dir) BK="$v" ;;
        home_list_preexisted) HOME_LIST_PREEXISTED="$v" ;;
        iface_detected) IFACE_META="$v" ;;
      esac
    done < "$META"
  fi
  case "$ASSIGN_PFXLEN" in (''|*[!0-9]*) ASSIGN_PFXLEN="128" ;; esac
  case "$HOME_LIST_PREEXISTED" in (''|*[!0-9]*) HOME_LIST_PREEXISTED=0 ;; esac
}

remove_ips() {
  local iface="$1"
  [ -f "$LIST" ] || return 0
  while read -r ip6; do
    [ -n "$ip6" ] || continue
    ip -6 addr del "$ip6/$ASSIGN_PFXLEN" dev "$iface" $ASSIGN_OPTS 2>/dev/null || true
    ip -6 addr del "$ip6/128" dev "$iface" 2>/dev/null || true
    ip -6 addr del "$ip6/64" dev "$iface" 2>/dev/null || true
  done < "$LIST"
}

do_uninstall_clean() {
  read_meta

  local iface="$IFACE_META"
  [ -n "${iface:-}" ] || iface="$(detect_iface || true)"

  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true
  [ -n "${iface:-}" ] && remove_ips "$iface"

  # 处理 home 文件：原本存在则恢复；否则删除
  if [ -n "${HOME_LIST_PATH:-}" ]; then
    if [ "$HOME_LIST_PREEXISTED" -eq 1 ] && [ -n "${BK:-}" ] && [ -f "$BK/old_home_list" ]; then
      cp -f "$BK/old_home_list" "$HOME_LIST_PATH" 2>/dev/null || true
    else
      rm -f "$HOME_LIST_PATH" 2>/dev/null || true
    fi
  fi

  rm -f "$UNIT" "$LIST" "$META" "$MONITOR_UNIT" "$MONITOR_SCRIPT" "$LEGACY_APPLY_UNIT" "$LEGACY_APPLY_TIMER_UNIT" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  # 卸载就是彻底清理备份目录
  rm -rf "$BACKUP_DIR" 2>/dev/null || true

  log "✅ 已彻底卸载：service/list/meta/备份/~/random-ipv6 已清理或恢复。"
  rm -f "$0" 2>/dev/null || true
}

do_restore_previous() {
  [ -d "$BACKUP_DIR" ] || { log "⚠️ 无备份目录，无法 restore，改为 uninstall。"; do_uninstall_clean; return 0; }
  local latest=""
  latest="$(cat "$BACKUP_DIR/latest" 2>/dev/null || true)"
  [ -n "$latest" ] || { log "⚠️ 无 latest 记录，无法 restore，改为 uninstall。"; do_uninstall_clean; return 0; }
  local bk="$BACKUP_DIR/$latest"
  [ -d "$bk" ] || { log "⚠️ 备份目录不存在，无法 restore，改为 uninstall。"; do_uninstall_clean; return 0; }

  read_meta

  local iface="$IFACE_META"
  [ -n "${iface:-}" ] || iface="$(detect_iface || true)"

  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  systemctl disable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true
  [ -n "${iface:-}" ] && remove_ips "$iface"

  if [ -n "${HOME_LIST_PATH:-}" ]; then
    if [ "$HOME_LIST_PREEXISTED" -eq 1 ] && [ -f "$bk/old_home_list" ]; then
      cp -f "$bk/old_home_list" "$HOME_LIST_PATH" 2>/dev/null || true
    else
      rm -f "$HOME_LIST_PATH" 2>/dev/null || true
    fi
  fi

  [ -f "$bk/old_unit" ] && cp -f "$bk/old_unit" "$UNIT" || rm -f "$UNIT" || true
  [ -f "$bk/old_list" ] && cp -f "$bk/old_list" "$LIST" || rm -f "$LIST" || true
  [ -f "$bk/old_meta" ] && cp -f "$bk/old_meta" "$META" || rm -f "$META" || true
  [ -f "$bk/old_monitor_unit" ] && cp -f "$bk/old_monitor_unit" "$MONITOR_UNIT" || rm -f "$MONITOR_UNIT" || true
  [ -f "$bk/old_monitor_script" ] && cp -p -f "$bk/old_monitor_script" "$MONITOR_SCRIPT" || rm -f "$MONITOR_SCRIPT" || true
  [ -f "$bk/old_apply_unit" ] && cp -f "$bk/old_apply_unit" "$LEGACY_APPLY_UNIT" || rm -f "$LEGACY_APPLY_UNIT" || true
  [ -f "$bk/old_apply_timer" ] && cp -f "$bk/old_apply_timer" "$LEGACY_APPLY_TIMER_UNIT" || rm -f "$LEGACY_APPLY_TIMER_UNIT" || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ -f "$bk/was_enabled" ] && grep -qx "enabled" "$bk/was_enabled"; then
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
  fi
  if [ -f "$bk/was_monitor_enabled" ] && grep -qx "enabled" "$bk/was_monitor_enabled"; then
    systemctl enable --now "$MONITOR_SERVICE" >/dev/null 2>&1 || true
  fi
  if [ -f "$bk/was_legacy_apply_timer_enabled" ] && grep -qx "enabled" "$bk/was_legacy_apply_timer_enabled"; then
    systemctl enable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  elif [ -f "$bk/was_apply_timer_enabled" ] && grep -qx "enabled" "$bk/was_apply_timer_enabled"; then
    systemctl enable --now "$LEGACY_APPLY_TIMER" >/dev/null 2>&1 || true
  fi
  if [ -f "$bk/was_legacy_apply_service_enabled" ] && grep -qx "enabled" "$bk/was_legacy_apply_service_enabled"; then
    systemctl enable --now "$LEGACY_APPLY_SERVICE" >/dev/null 2>&1 || true
  fi

  log "✅ 已恢复到运行脚本前的旧版本（如果当时存在）。"
}

case "$MODE" in
  --uninstall) do_uninstall_clean ;;
  --restore) do_restore_previous ;;
  *) die "用法：$0 --uninstall | --restore" ;;
esac
EOS
chmod +x "$RESTORE_BIN"

# 写入 ~/random-ipv6：5个IP + 卸载/恢复命令
{
  cat "$LIST"
  echo
  echo "UNINSTALL: sudo $RESTORE_BIN --uninstall"
  echo "RESTORE:   sudo $RESTORE_BIN --restore"
  echo "STATUS:    systemctl status $SERVICE --no-pager"
} > "$HOME_LIST"
chmod 600 "$HOME_LIST" 2>/dev/null || true

log "========================================================"
log "🎉 成功：已绑定 5 个 IPv6 并写入开机服务"
log "📄 系统列表: $LIST"
log "📄 家目录文件: $HOME_LIST（含卸载/恢复命令）"
log "🧩 unit: $UNIT"
log "🛠️ 还原脚本: $RESTORE_BIN"
log "========================================================"

ROLLBACK_NEEDED=0
