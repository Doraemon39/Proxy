本文默认在 `root` 下执行；如果你用普通用户，请在需要权限的命令前加 `sudo`。

1.确认是否有打开BBR加速

```
sysctl net.ipv4.tcp_congestion_control | grep bbr && echo "BBR 已启用" || echo "启用失败"
lsmod | grep bbr
```
   若没有打开BBR，则进行配置BBR
 ```
 echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
 echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
 sudo sysctl -p
 ```

这样就打开了原版的BBR

若你想要开启BBRv3，则这样操作：

```
apt install gpg
```

```
wget -qO - https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg
```

```
echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | sudo tee /etc/apt/sources.list.d/xanmod-release.list
```

```
sudo apt update
```

```
sudo apt install linux-xanmod-x64v3
```

```
注意：v3 指的是 x86-64-v3 微架构级别，需要较新的 CPU 支持
通过 cat /proc/cpuinfo | grep avx2 命令检查是否支持 v3
若不支持 可以选择 linux-xanmod-x64v2 或 linux-xanmod-lts
```

```
reboot
```

```
uname -r 
查看内核是否为：...-xanmod...
```

```
nano /etc/sysctl.conf
```

```
#添加以下行，或者修改
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

```
sudo sysctl --system
```

```
检查
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

2.安装Xray

```
为什么我不使用3xui，就是因为想修改某些参数都不够方便
```

```
安装并升级 Xray-core 和地理数据，默认使用 User=nobody，但不会覆盖已有服务文件中的 User 设置
```
```
apt update
```

```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

```
ps aux | grep xray
检查是否为Nobody，保证最小权限
```

3.配置文件config.json 

配置模板：https://github.com/chika0801/Xray-examples/tree/main/VLESS-Vision-REALITY

```
Vless+Vison+Reality
需要一个在大陆能直接访问的国外网站(服务器必须在境外)，支持 TLSv1.3、X25519 与 H2，域名非跳转用(例如主域名可能被用于跳转到 www)，同时不能有CDN
```

当然，可以按照我的步骤来：

生成X25519密钥对，用于客户端认证，务必保存这两个密钥，待会使用

```
/usr/local/bin/xray x25519
```

生成UUID，保存下来，待会使用

```
/usr/local/bin/xray uuid
```

生成shortid，保存下来，待会使用

```
openssl rand -hex 8
```

```
nano /usr/local/etc/xray/config.json
```

```
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "inboundTag": [
          "v4first"
        ],
        "outboundTag": "ipv4-first"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": 443,
      "protocol": "vless",
      "tag": "v4first",
      "settings": {
        "clients": [
          {
            "id": "【在此处粘贴你的 UUID】",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.yahoo.com:443",
          "xver": 0,
          "serverNames": [
            "www.yahoo.com",
            "yahoo.com"
          ],
          "privateKey": "【在此处粘贴你的私钥】",
          "shortIds": [
            "【在此处粘贴你的shortID】"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    },
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "ipv4-first"
    }
  ]
}

```

```
systemctl restart xray
```

```bash
# 确认服务正常
systemctl status xray --no-pager

# 确认 443 在监听
ss -lntp | grep ':443'
```

```bash
# 如启用了 UFW，放行 443/TCP
sudo ufw allow 443/tcp
```

然后就可以使用了

```
vless://【你的UUID】@【服务器地址】:【端口】?flow=xtls-rprx-vision&security=reality&sni=【你的SNI】&fp=chrome&pbk=【你的公钥PublicKey】&sid=【你的ShortID】&type=tcp&packet-encoding=xudp#【节点名称】
```

```
其中第一个 serverNames 作为你的SNI
```

Clash mihomo的配置：

```
proxies:
- name: "vless"
  type: vless
  server: server
  port: 443
  udp: true
  uuid: uuid
  flow: xtls-rprx-vision
  packet-encoding: xudp

  tls: true
  servername: example.com
  alpn:
  - h2
  - http/1.1
  fingerprint: xxxx
  client-fingerprint: chrome
  skip-cert-verify: true
  reality-opts:
    public-key: xxxx
    short-id: xxxx
  encryption: ""

  network: tcp

  smux:
    enabled: false
```





**关于BBR调优**

1. 512MB–1GB 可用内存｜RTT≈120ms｜1–1.5Gbps

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

net.ipv4.tcp_rmem = 8192 131072 33554432
net.ipv4.tcp_wmem = 8192 65536  33554432

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = 1048576

net.ipv4.tcp_max_orphans = 4096

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15

net.ipv4.ip_forward = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

vm.swappiness = 10
```

2. 1GB–2GB 可用内存｜RTT≈190–240ms｜2Gbps

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

net.ipv4.tcp_rmem = 8192 131072 67108864
net.ipv4.tcp_wmem = 8192 65536  67108864

net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 16384
fs.file-max = 1048576
net.ipv4.tcp_max_orphans = 8192

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15

net.ipv4.ip_forward = 1

net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

vm.swappiness = 10
```

注意：必须systemd 给 xray.service 配 LimitNOFILE

```
systemctl status xray --no-pager
```

```
sudo systemctl edit xray
```

```
[Service]
LimitNOFILE=1048576
# 或者显式 soft:hard
# LimitNOFILE=1048576:1048576
```

```
sudo systemctl daemon-reload
sudo systemctl restart xray
```

验证：

```
systemctl show xray -p LimitNOFILE
```

```
pid=$(pidof xray || pidof xray-core)
cat /proc/$pid/limits | grep -i "Max open files"
```

看到类似 `1048576` 才算真的生效。

```
fq：主要面向本机产生的流量；核心优势是按流（per-flow）pacing，并且能尊重 TCP 栈的 pacing/EDT 要求（可开关 pacing）。

fq_codel：在“按流公平排队”的基础上叠加 CoDel AQM，用于控延迟/抗 bufferbloat，适合“出口会堆队列、需要主动管理排队延迟”的场景。其 man page 没有 fq 那种 pacing 开关/描述，更偏向“FQ + AQM”。

CAKE：一个可整形的 qdisc，集成 FQ + AQM（COBALT）+ deficit-mode shaper + 流/主机隔离等；默认 unlimited（不整形），默认隔离模式是 triple-isolate。多数情况下只要把 bandwidth 配好就能得到很好的效果。
```

```
我 → vps1（xray-core）
1.优先：CAKE + bandwidth(略低于实际带宽) + dual-dsthost（或 triple-isolate）
如果不想做整形（不设 bandwidth）:使用fq(支持pacing)
唯有VPS的出口带宽 < 你的接收带宽，使用fq_codel
```

```
我 → vps1（realm）→ vps2（xray-core）
1.vps1同样优先 CAKE + bandwidth + dual-dsthost/triple-isolate
如果不想做整形（不设 bandwidth）:使用fq(支持pacing)
2.vps2同样优先 CAKE + bandwidth + dual-dsthost/triple-isolate
如果不想做整形（不设 bandwidth）:使用fq(支持pacing)
```

```
队列（拥堵）永远产生在“快口”往“慢口”灌水的地方。
```

```
CAKE 默认就是 unlimited（不整形），所有设置都可选；只是多数场景想获得最明显收益，通常需要设置 bandwidth。

如果你设置了 bandwidth，就要确保这个值是可持续达到的上限，并且通常略低于实测极限；
如果你无法稳定估计带宽（尤其是上行），那就别强行整形：用 fq（更偏 pacing）或 fq_codel（更偏控延迟）
```



**Cake流量整型**

```
apt install -y iproute2 kmod ethtool
```

1.创建 `/etc/default/qos-cake`

```
nano /etc/default/qos-cake
```

```
# ===== 必填/常用 =====
UP_BW="20mbit"                 # 上行整形带宽：建议略低于你可持续上行（比如 90~95%）
MODE="triple-isolate"          # 或 dual-srchost / dual-dsthost / triple-isolate 等
DIFFSERV="diffserv4"           # diffserv4 常用；不想分级就留空：DIFFSERV=""

# ===== NAT 相关 =====
# auto：检测到有 MASQUERADE/masquerade 规则才加 nat
# yes：强制加 nat（你确认是路由/NAT 网关时）
# no：不加 nat（大多数“单机 VPS”建议 no 或 auto）
NAT="auto"

# ===== 可选优化 =====
ACK_FILTER="yes"               # 上行整形 + 大量下载时 ACK 回传可能有帮助；不想要可改 no
RTT=""                         # 可选：比如 50ms/100ms；不确定建议留空

# ===== 下行整形（默认关闭）=====
# 如果你想连下行也整形（通常需要 IFB），填一个带宽即可：
# DOWN_BW="100mbit"
DOWN_BW=""

# IFB 设备名（一般不用改）
IFB_DEV="ifb0"

# 额外 CAKE 参数（高级用法，默认留空）
# 比如：EXTRA_CAKE_OPTS="besteffort"
EXTRA_CAKE_OPTS=""
```

2.创建脚本

```
nano /usr/local/sbin/qos-cake.sh
```

```
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

remove_wan_cake_root_if_present() {
  local dev="$1"

  if ! tc qdisc show dev "$dev" 2>/dev/null | grep -qE '\bqdisc[[:space:]]+cake\b.*\broot\b'; then
    echo "INFO: Root qdisc on '$dev' is not cake, skipping root qdisc delete." >&2
    return 0
  fi

  tc qdisc del dev "$dev" root 2>/dev/null || true

  if tc qdisc show dev "$dev" 2>/dev/null | grep -qE '\bqdisc[[:space:]]+cake\b.*\broot\b'; then
    echo "ERROR: Failed to remove CAKE root qdisc on '$dev'." >&2
    return 1
  fi
}

apply_egress() {
  local dev="$1"
  local nf=""

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
  local nf=""

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
  local stop_failed=0

  if [[ -z "$WAN_IF" ]]; then
    WAN_IF="$(detect_wan_if || true)"
  fi

  if [[ -n "$WAN_IF" ]]; then
    remove_wan_cake_root_if_present "$WAN_IF" || stop_failed=1
    delete_ingress_redirect_filters "$WAN_IF"
    restore_offload_if_needed "$WAN_IF" || stop_failed=1
  else
    echo "WARN: Cannot detect WAN interface, skipping WAN qdisc cleanup." >&2
    stop_failed=1
  fi

  # IFB 清理（默认不删设备，避免影响其他服务）
  tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
  if [[ "${DELETE_IFB_ON_STOP,,}" == "yes" ]]; then
    ip link set "$IFB_DEV" down 2>/dev/null || true
    ip link del "$IFB_DEV" 2>/dev/null || true
  fi

  (( stop_failed == 0 )) || return 1
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

```

```
sudo chmod +x /usr/local/sbin/qos-cake.sh
```

3. systemd

```
nano /etc/systemd/system/qos-cake@.service
```

```
[Unit]
Description=Apply CAKE qdisc on interface %I
Wants=network-online.target
After=network-online.target
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/qos-cake.sh start %I
ExecStop=/usr/local/sbin/qos-cake.sh stop %I

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
```

```
# 找默认出口接口（一般是 eth0/ens3）
ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
```

```
# 假设输出 eth0
sudo systemctl enable --now qos-cake@eth0.service
```

4.验证

```
sudo /usr/local/sbin/qos-cake.sh status eth0
tc -s qdisc show dev eth0
```



5.关闭流量整型

以下示例都以 `eth0` 为例，按你的实际网卡名替换。

临时关闭（可随时再启动）

```
# 关闭 CAKE（建议显式带网卡名）
sudo systemctl stop qos-cake@eth0.service
```

关闭开机自启（保留文件）

```
sudo systemctl disable qos-cake@eth0.service
```

重新开启

```
sudo systemctl enable --now qos-cake@eth0.service
```

彻底删除 CAKE 脚本与服务

```
# 先停掉并清理 qdisc/filter
sudo /usr/local/sbin/qos-cake.sh stop eth0 || true
sudo systemctl disable --now qos-cake@eth0.service || true

# 删除 systemd 单元和脚本配置
sudo rm -f /etc/systemd/system/qos-cake@.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/sbin/qos-cake.sh
sudo rm -f /etc/default/qos-cake

# 可选：如果你确认不再使用 ifb0，可删除
sudo ip link set ifb0 down 2>/dev/null || true
sudo ip link del ifb0 2>/dev/null || true
```

网卡变更时建议

```
# 先清旧网卡
sudo /usr/local/sbin/qos-cake.sh stop <旧网卡>

# 再启新网卡
sudo /usr/local/sbin/qos-cake.sh start <新网卡>
```

不要只“停进程”。`qos-cake.sh` 不是常驻进程，规则写入内核后必须执行 `stop` 才会清理。

