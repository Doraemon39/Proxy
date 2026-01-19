#!/usr/bin/env bash
set -euo pipefail

SERVICE="ipv6-static.service"
UNIT="/etc/systemd/system/${SERVICE}"
LIST="/etc/ipv6-static.list"
META="/etc/ipv6-static.meta"
BACKUP_DIR="/etc/ipv6-static.backup"
RESTORE_BIN="/usr/local/sbin/ipv6-static-restore"

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
  if [ -n "${BK:-}" ] && [ -f "$BK/was_enabled" ] && grep -qx "enabled" "$BK/was_enabled"; then
    was_enabled=1
  fi

  warn "发生错误，开始回滚（恢复运行前状态，尽量不留残留）..."
  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true

  if [ -n "${CHOSEN_IFACE:-}" ]; then
    cleanup_added_ips "$CHOSEN_IFACE"
  fi

  restore_backup_state
  systemctl daemon-reload >/dev/null 2>&1 || true

  if [ "$was_enabled" -eq 1 ]; then
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
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

TS="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo "unknown_time")"
BK="$BACKUP_DIR/$TS"
mkdir -p "$BK"
printf '%s' "$TS" > "$BACKUP_DIR/latest"

[ -f "$UNIT" ] && cp -f "$UNIT" "$BK/old_unit"
[ -f "$LIST" ] && cp -f "$LIST" "$BK/old_list"
[ -f "$META" ] && cp -f "$META" "$BK/old_meta"
[ -f "$RESTORE_BIN" ] && cp -p -f "$RESTORE_BIN" "$BK/old_restore_bin"
if systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then echo "enabled" > "$BK/was_enabled"; else echo "disabled" > "$BK/was_enabled"; fi

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
    ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{exit 0} END{exit 1}' && { echo "$dev"; return 0; }
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
  ip -6 route show dev "$iface" proto kernel scope link 2>/dev/null \
    | awk '{p=$1; if(p ~ /^fe80:/) next; if(p ~ /\/[0-9]+$/){print p; exit}}'
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
    printf "%04x" "$((16#$h))"
    ((i<7)) && printf ":"
  done
}

norm6() { expand_ipv6 "$1" | tr -d ':'; }

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
  if have od; then
    od -An -N2 -tx2 /dev/urandom | tr -d ' \n'
  else
    hexdump -n 2 -e '1/2 "%04x"' /dev/urandom
  fi
}

BASE_EXP="$(expand_ipv6 "$BASE_IP")"
IFS=':' read -r -a BASE_ARR <<< "$BASE_EXP"

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
}

# -------------------- 生成 5 个地址 --------------------
ROLLBACK_NEEDED=1
: > "$LIST"
chmod 600 "$LIST" || true
count=0
while [ "$count" -lt 5 ]; do
  ip6="$(gen_one_ip)"
  grep -qx "$ip6" "$LIST" 2>/dev/null && continue
  echo "$ip6" >> "$LIST"
  count=$((count+1))
done

# -------------------- 选择添加方式（回退） --------------------
try_add_del() {
  local ip6="$1" pfx="$2"; shift 2
  local opts="$*"
  if ip -6 addr add "$ip6/$pfx" dev "$IFACE" $opts 2>/dev/null; then
    ip -6 addr del "$ip6/$pfx" dev "$IFACE" $opts 2>/dev/null || true
    return 0
  fi
  return 1
}

first_ip="$(head -n1 "$LIST")"
if try_add_del "$first_ip" 128 "noprefixroute"; then
  ASSIGN_PFXLEN=128; ASSIGN_OPTS="noprefixroute"
elif try_add_del "$first_ip" 128 ""; then
  ASSIGN_PFXLEN=128; ASSIGN_OPTS=""
elif try_add_del "$first_ip" "$GEN_PFXLEN" ""; then
  ASSIGN_PFXLEN="$GEN_PFXLEN"; ASSIGN_OPTS=""
elif try_add_del "$first_ip" "$GEN_PFXLEN" "noprefixroute"; then
  ASSIGN_PFXLEN="$GEN_PFXLEN"; ASSIGN_OPTS="noprefixroute"
else
  die "多种方式仍无法添加 IPv6（可能服务商禁用额外 IPv6 或需要额外网络设置）"
fi
log "✅ 添加方式：/$ASSIGN_PFXLEN ${ASSIGN_OPTS:-"(no extra opts)"}"

# -------------------- 写 unit 并启动 --------------------
systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true

cat > "$UNIT" <<EOF
[Unit]
Description=Add 5 Static IPv6 Addresses (generated once, persistent)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'IPBIN=\$(command -v ip 2>/dev/null || true); [ -n "\$IPBIN" ] || IPBIN=/usr/sbin/ip; [ -x "\$IPBIN" ] || IPBIN=/sbin/ip; \
getiface() { \
IFACE=\$("\$IPBIN" -6 route show default 2>/dev/null | awk "NR==1{for(i=1;i<=NF;i++) if(\\\$i==\\"dev\\"){print \\\$(i+1); exit}}"); \
[ -n "\$IFACE" ] || IFACE=\$("\$IPBIN" -6 route get 2001:4860:4860::8888 2>/dev/null | awk "{for(i=1;i<=NF;i++) if(\\\$i==\\"dev\\"){print \\\$(i+1); exit}}"); \
echo "\$IFACE"; \
}; \
IFACE="\$(getiface)"; \
tries=0; \
while [ -z "\$IFACE" ] && [ "\$tries" -lt 30 ]; do sleep 2; IFACE="\$(getiface)"; tries=\$((tries+1)); done; \
[ -n "\$IFACE" ] || { echo "ipv6-static: cannot detect IPv6 default-route interface" >&2; exit 1; }; \
while read -r ip6; do [ -n "\$ip6" ] || continue; "\$IPBIN" -6 addr add "\$ip6/$ASSIGN_PFXLEN" dev "\$IFACE" $ASSIGN_OPTS 2>/dev/null || true; done < $LIST'

ExecStop=/bin/sh -c 'IPBIN=\$(command -v ip 2>/dev/null || true); [ -n "\$IPBIN" ] || IPBIN=/usr/sbin/ip; [ -x "\$IPBIN" ] || IPBIN=/sbin/ip; \
IFACE=\$("\$IPBIN" -6 route show default 2>/dev/null | awk "NR==1{for(i=1;i<=NF;i++) if(\\\$i==\\"dev\\"){print \\\$(i+1); exit}}"); \
[ -n "\$IFACE" ] || IFACE=\$("\$IPBIN" -6 route get 2001:4860:4860::8888 2>/dev/null | awk "{for(i=1;i<=NF;i++) if(\\\$i==\\"dev\\"){print \\\$(i+1); exit}}"); \
[ -n "\$IFACE" ] || exit 0; \
while read -r ip6; do [ -n "\$ip6" ] || continue; "\$IPBIN" -6 addr del "\$ip6/$ASSIGN_PFXLEN" dev "\$IFACE" $ASSIGN_OPTS 2>/dev/null || true; done < $LIST'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"

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
  route_check "$ip6" || die "route-get 失败：源地址 $ip6 无法选择有效路由"
done < "$LIST"
log "✅ DAD + route-get 通过"

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

SERVICE="ipv6-static.service"
UNIT="/etc/systemd/system/${SERVICE}"
LIST="/etc/ipv6-static.list"
META="/etc/ipv6-static.meta"
BACKUP_DIR="/etc/ipv6-static.backup"

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
    ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{exit 0} END{exit 1}' && { echo "$dev"; return 0; }
  done < <(ip -o link show up 2>/dev/null | awk -F': ' '{split($2,a,"@"); print a[1]}')
  return 1
}

read_meta() {
  ASSIGN_PFXLEN="128"
  ASSIGN_OPTS=""
  HOME_LIST_PATH=""
  BK=""
  HOME_LIST_PREEXISTED=0
  if [ -f "$META" ]; then
    # shellcheck disable=SC1090
    source <(sed 's/^\([^=]*\)=/export \1=/' "$META" 2>/dev/null || true)
    [ -n "${assign_prefixlen:-}" ] && ASSIGN_PFXLEN="$assign_prefixlen"
    [ -n "${assign_opts:-}" ] && ASSIGN_OPTS="$assign_opts"
    [ -n "${home_list_path:-}" ] && HOME_LIST_PATH="$home_list_path"
    [ -n "${backup_dir:-}" ] && BK="$backup_dir"
    [ -n "${home_list_preexisted:-}" ] && HOME_LIST_PREEXISTED="$home_list_preexisted"
  fi
}

remove_ips() {
  local iface="$1"
  [ -f "$LIST" ] || return 0
  read_meta
  while read -r ip6; do
    [ -n "$ip6" ] || continue
    ip -6 addr del "$ip6/$ASSIGN_PFXLEN" dev "$iface" $ASSIGN_OPTS 2>/dev/null || true
    ip -6 addr del "$ip6/128" dev "$iface" 2>/dev/null || true
    ip -6 addr del "$ip6/64" dev "$iface" 2>/dev/null || true
  done < "$LIST"
}

do_uninstall_clean() {
  local iface=""
  iface="$(detect_iface || true)"

  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  [ -n "${iface:-}" ] && remove_ips "$iface"

  read_meta

  # 处理 home 文件：原本存在则恢复；否则删除
  if [ -n "${HOME_LIST_PATH:-}" ]; then
    if [ "$HOME_LIST_PREEXISTED" -eq 1 ] && [ -n "${BK:-}" ] && [ -f "$BK/old_home_list" ]; then
      cp -f "$BK/old_home_list" "$HOME_LIST_PATH" 2>/dev/null || true
    else
      rm -f "$HOME_LIST_PATH" 2>/dev/null || true
    fi
  fi

  rm -f "$UNIT" "$LIST" "$META" 2>/dev/null || true
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

  local iface=""
  iface="$(detect_iface || true)"

  systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
  [ -n "${iface:-}" ] && remove_ips "$iface"

  [ -f "$bk/old_unit" ] && cp -f "$bk/old_unit" "$UNIT" || rm -f "$UNIT" || true
  [ -f "$bk/old_list" ] && cp -f "$bk/old_list" "$LIST" || rm -f "$LIST" || true
  [ -f "$bk/old_meta" ] && cp -f "$bk/old_meta" "$META" || rm -f "$META" || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  if [ -f "$bk/was_enabled" ] && grep -qx "enabled" "$bk/was_enabled"; then
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
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
