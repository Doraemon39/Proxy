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
net.core.default_qdisc=fq_pie
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

配置模板：https://github.com/chika0801/Xray-examples/tree/main/VLESS-Vision-REALITYVle

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

然后就可以使用了

```
vless://【你的UUID】@【服务器地址】:【端口】?flow=xtls-rprx-vision&security=reality&sni=【你的SNI】&fp=chrome&pbk=【你的公钥Public key/Password】&sid=【你的ShortID】&type=tcp#【节点名称】
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





