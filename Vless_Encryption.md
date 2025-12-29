## VLESS Encryption

**VLESS Encryption** 是 VLESS 协议的可选加密/认证层，提供前向安全（PFS）、0-RTT 复用与后量子相关设计取舍；它**不是伪装/抗探测方案**。在受限网络环境中不应将其作为单独的穿透手段，仍需结合合适的传输层机制。

与 SS/VMess 等“自带加密的代理协议”相比，它在安全性（如前向安全、抗量子取舍）与性能路径（如建议配合 XTLS 避免二次加解密）上有不同的设计目标，但并不意味着在所有场景都“绝对更快/绝对更强”。
 此外，VLESS Encryption 默认支持 XUDP/UoT 相关能力，用于改善 UDP 在部分网络条件下的可用性，实际效果取决于链路与转发环境。

### 一、服务器端配置

#### (1) 安装Xray

```
apt update
```

```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

#### (2) 生成 VLESS Encryption 参数

为避免手动拼接导致的格式错误，建议直接用 Xray 自带的生成器生成一对可用参数：`decryption`（服务端用）和 `encryption`（客户端用）

```
/usr/local/bin/xray vlessenc
```

命令输出里通常会给出两套“认证块”方案（**二选一**即可）：[Project X+2Project X+2](https://xtls.github.io/document/command.html)

- **X25519**：参数更短、配置更直观
- **ML-KEM-768**：用于“后量子认证”的方案，参数更长

> 注意：这里的“二选一”指的是**最后一个认证块**选用 X25519 或 ML-KEM-768；不管你选哪一种，握手方式块目前固定是 `mlkem768x25519plus`。
>
> 推荐使用后者

输出示例（只需要把整串原样复制进配置，不要删块、不要漏点）：

```
"decryption":"mlkem768x25519plus.native.600s.xxxxxxxxxx"
"encryption":"mlkem768x25519plus.native.0rtt.xxxx(很长)"
```

##### 关于 native / xorpub / random

第二块表示“外观/混淆方式”，服务端与客户端必须一致：

- `native`：原始格式数据包
- `xorpub`：原始格式 + **混淆公钥部分**（更低特征）
- `random`：全随机外观（更像 VMess/SS 的随机数据）

推荐使用 `xorpub`，把生成结果里的第二块从 `native` 改成 `xorpub`即可。服务端 `decryption` 和客户端 `encryption` 同步同步更改。另外，mihomo 文档也提到 `native/xorpub` 的 Vision 能配合 Splice；`random` 更偏“全随机外观”。

#### (3) 生成UUID

```
/usr/local/bin/xray uuid
```

#### (4) 修改Xray配置

```
nano /usr/local/etc/xray/config.json
```

```
{
  "log": {
    "access": "none",
    "error": "",
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
      }
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "【粘贴刚刚生成的UUID】",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "【粘贴 vlessenc 输出的 decryption 整串】"
      },
      "streamSettings": {
        "network": "tcp"
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
    }
  ]
}
```

```
systemctl restart xray
```

```
systemctl status xray
```

### 二 、客户端配置(Clash mihomo)

```
proxies:
- name: "vless"
  type: vless
  server: server
  port: 443
  udp: true
  uuid: 【粘贴你的UUID】
  flow: xtls-rprx-vision
  packet-encoding: xudp
  encryption: "【粘贴 vlessenc 输出的 encryption 整串】"
  network: tcp
```

可分享的形式：

```
vless://【UUID】@server:端口?encryption=【encryption整串】&security=none&flow=xtls-rprx-vision&packetEncoding=xudp&type=tcp#Vless Encryption
```



在官方文档中，你能看见以下这种形式：

```
mlkem768x25519plus.xorpub.0rtt.（X25519...）.（ML-KEM-768...）
```

这种多块（Multi-block）配置主要设计用于**认证**或**中转链路（Relay）**场景，在不同模式下核心的处理逻辑截然不同：

1. **单跳模式（Direct/No Relay）：遵循“末位生效”原则** 在非中转场景下，核心逻辑会将配置列表中的**最后一个块**识别为“用于认证的参数”。
   - **客户端（Encryption）：** 使用最后一个块的配置（如 ML-KEM Client）对服务端进行认证。
   - **服务端（Decryption）：** 使用最后一个块的配置（如 X25519 PrivateKey 或 ML-KEM Seed）来验证客户端。
2. **多跳模式（Relay Chain）：逐级消费** 客户端会将配置中的多个公钥依次打包进 `ivAndRelays`，实现链路的层层解密。每个中转节点“消费”掉一层配置，直到最后一级到达最终服务端。

**建议：** 在普通的单跳（直连）场景中，**强烈建议只保留一个认证块**。 如果你的列表中包含多个块（例如前有 X25519，最后是 ML-KEM-768），核心只会取最后一个（即 ML-KEM-768）作为实际认证参数，并且增加了配置文件的复杂度和出错概率。
