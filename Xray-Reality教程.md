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
NAT="no"

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
将Cake.sh的代码完整粘贴进去
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

