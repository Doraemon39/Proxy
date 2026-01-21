### 给每个用户分配独立 IPv6 出口地址（IPv6 优先，IPv4 兜底）

利用 VPS 配备的 /64 IPv6 子网，通过划定 5 个静态出口 IP，可达成**用户级流量隔离**。这不仅能降低因单一地址受损导致的业务中断风险，还能显著提升在高风控、单 IP 限制场景下的通过率。 **潜在挑战：** 无法防范针对子网段的屏蔽

**目标：**

- 给每个用户分配 **固定独立的 IPv6 出口地址**（用户级隔离）。
- **目标有 IPv6（存在 AAAA）时强制走 IPv6**。
- **目标无 IPv6（没有 AAAA）时才走 IPv4 兜底**。

#### 前提检查

1. 你的 VPS 提供商确实把 **/64（或更大）IPv6 前缀路由到这台机器**，并允许你在同一网卡上挂多条 IPv6。
2. 如果你使用了 Xray 内置 DNS，**不要把查询策略限制为仅 IPv4**，否则永远解析不到 AAAA（IPv6），`::/0` 规则就不会命中



#### 第一步：一键生成 5 个 IPv6 地址（/128）并绑定 IP

我们将使用自动化脚本来探测网络环境、生成随机 IP 并持久化挂载。

1. **创建脚本文件**

   ```bash
   nano ipv6-static-setup-fixed-final.bash
   ```

   ```bash
   # 将 ipv6-static-setup-fixed-final.bash 复制进去
   ```

   按 `Ctrl+O` 保存，再按 `Ctrl+X` 退出。

2. **赋予权限并执行**

   ```bash
   chmod +x ipv6-static-setup-fixed-final.bash
   bash ./ipv6-static-setup-fixed-final.bash
   ```

3. **查看生成的地址** 执行成功后，系统会自动配置好开机自启。你可以查看生成的 5 个地址：

   ```bash
   cat ~/random-ipv6
   ```

4. **清理残留文件**

   ```bash
   rm ./ipv6-static-setup-fixed-final.bash
   ```



#### 第二步：配置 Xray-core 出站 (Outbounds)

你需要修改 Xray 的配置文件（通常是 `config.json`），利用 `sendThrough` 字段指定出口 IP。

**1. 修改 Outbounds（出站设置）** 在 `outbounds` 列表中添加 5 个对应的出口对象：

```
{
  "outbounds": [
    // 兜底：强制 IPv4
    {
      "tag": "out-ipv4-only",
      "protocol": "freedom",
      "settings": { "domainStrategy": "ForceIPv4" }
    },

    // 黑洞：用于 block
    {
      "tag": "block",
      "protocol": "blackhole"
    },

    // 用户 1~5：固定 IPv6 源地址 + 强制 IPv6
    {
      "tag": "out-v6-1",
      "protocol": "freedom",
      "sendThrough": "你的第1个IPv6地址",
      "settings": { "domainStrategy": "ForceIPv6" }
    },
    {
      "tag": "out-v6-2",
      "protocol": "freedom",
      "sendThrough": "你的第2个IPv6地址",
      "settings": { "domainStrategy": "ForceIPv6" }
    }
    // ... out-v6-3/out-v6-4/out-v6-5 同理 ...
  ]
}
```

> * Xray 没有匹配到任何路由规则时，会使用 outbounds 列表的**第一个**作为默认出口；Routing 优先级高于 Outbounds 顺序，Outbounds 顺序只影响“无规则命中时的默认出口
>* `out-ipv4-only` 放第一个：作为 **IPv4 兜底出口**
> 
>



**2. 修改 Routing（路由设置）**

```bash
{
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      // 可选：屏蔽内网地址（按需保留）
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },

      // 建议：屏蔽 QUIC，避免 UDP/443 绕开你的 IPv6 策略
      // 也可改成更严格：network=udp + port=443
      {
        "type": "field",
        "protocol": ["quic"],
        "outboundTag": "block"
      },

      // 用户 1：只有当目标存在 IPv6（解析出 ::/0）才走 out-v6-1
      {
        "type": "field",
        "user": ["user1@email.com"],
        "ip": ["::/0"],
        "outboundTag": "out-v6-1"
      },

      // 用户 2
      {
        "type": "field",
        "user": ["user2@email.com"],
        "ip": ["::/0"],
        "outboundTag": "out-v6-2"
      }

      // ... user3~user5 同理 ...

      // 兜底：其余全部走 IPv4-only（也可以不写，依赖 outbounds[0] 默认出口）
      ,
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "out-ipv4-only"
      }
    ]
  }
}
```

1. 只有当路由系统能把“域名”解析成 IP，`ip: ["::/0"]` 才可能匹配到 IPv6。
2. **routing** 必须开 `IPOnDemand` 或 `IPIfNonMatch `



#### 为什么建议禁用 QUIC（否则“IPv6 必走”会被 UDP 绕开）

很多浏览器会优先用 QUIC（UDP/443）。而 Freedom 文档明确提到：

- 在发送 UDP 时，Freedom 出于一些原因会无视 sockopt 的 domainStrategy，并在默认状态下强制偏好 IPv4。

这意味着：

- 即使目标网站支持 IPv6，你也可能看到某些访问走了 IPv4（因为它走的是 UDP/QUIC）。

解决：

- 最简单粗暴：在 routing 里直接 `protocol: ["quic"] -> block`（上面已经给了规则）。
- 浏览器会自动回落到 TCP（HTTP/2 或 HTTP/1.1），这样你的 `ForceIPv6 + ::/0` 逻辑才真正“锁死”。



#### 进阶：如果你真要“IPv6 连接失败后自动改走 IPv4”

上面方案能保证：**目标支持 IPv6（有 AAAA）就走 IPv6；目标不支持 IPv6 才走 IPv4。**

但要做到：

- 目标有 AAAA
- 但 IPv6 线路失败
- Xray 自动改走 IPv4

你需要用到 **HappyEyeballs** 这种“IPv6/IPv4 竞速/回退”机制。

Xray 在 `streamSettings.sockopt.happyEyeballs` 提供了 RFC-8305 实现，并且支持 `prioritizeIPv6` 参数。

> 参考：https://xtls.github.io/config/transport.html

⚠️ 关键难点：

- 现在用 `sendThrough: <固定IPv6>` 把 IPv6 出口绑死了。
- 一旦要改走 IPv4，固定 bind IPv6 会导致 IPv4 拨号失败（本地地址族不匹配）。

所以要同时满足“按用户固定 IPv6” + “失败回退 IPv4”，通常要改成：

- 不用 `sendThrough` 固定 bind；
- 改用 `sockopt.mark` 给不同用户的出站打不同 fwmark；
- 用 Linux `ip rule`/`ip -6 route` 做策略路由，把不同 mark 的 IPv6 流量固定到各自的源地址/路由表；
- 再在 sockopt 启用 HappyEyeballs（并设置 `prioritizeIPv6: true`）进行失败回退。

这套方案更重、也更容易踩系统网络坑，但它是“真正意义上的失败回退”的方向。



**Xray-core 核心机制答疑与原理解析**

**Routing 与 Outbounds：谁决定最终走哪个出口？**

1. 只要 **Routing 命中规则**，就不会受 `outbounds` 顺序影响。
2. 只有在 **Routing 完全没有命中任何规则时**，Xray 才会启用**“默认行为”**：**使用 `outbounds` 列表中的第一个出站（index 0）**。

“虽然 Xray 具备‘默认回落至 Index 0’的机制，但这属于**隐式逻辑**，并非最佳实践。**显式**兜底是更推荐的做法：在 Routing 规则的末尾，**显式**添加一条‘捕获所有流量’的规则作为兜底。”

```
{
  "type": "field",
  "network": "tcp,udp",
  "outboundTag": "Direct"
}
```

这条规则像一张巨大的网，捞住了前面所有未匹配的漏网之鱼。



**Routing** 的 `domainStrategy` 对比 **Outbound**  的`domainStrategy`

这里有两类完全不同的 `domainStrategy`：

**一、Routing 的 `domainStrategy`（AsIs / IPIfNonMatch / IPOnDemand）**

它只决定：**路由阶段要不要把域名解析成 IP 来参与 IP 规则匹配**。

- **IPIfNonMatch**：**先用**域名规则匹配；如果匹配不出结果，**再用**内置 DNS 把域名解析成 IP，然后再跑一遍 IP 规则匹配。 
- **IPOnDemand**：只要路由匹配过程中碰到**任何**“基于 IP 的规则”，就会**立刻**把域名解析成 IP 来参与匹配。
-  **AsIs**：只看表面，绝不解析。在路由阶段，**AsIs** 策略会让 Xray **完全跳过** DNS 解析步骤。它**只**使用流量进入时原本携带的信息（通常是域名）去匹配规则。

>  `routing.ip: ["::/0"]` 这类规则，**是否会触发解析、何时解析**，就是由这里控制的。
>
> 

**二、Outbound / `streamSettings.sockopt` 的 `domainStrategy`（UseIPv4/UseIPv6/Force…）**

它决定的是：**出站连接时，域名要怎么解析、怎么选 IPv4/IPv6 地址去拨号**。

**1.核心模式行为**

**`AsIs`（默认 / “原生”模式）**

- **解析机制**：不做任何特殊处理，直接调用 Go 语言标准的 `net.Dial`。
- **DNS 来源**：完全依赖系统（OS）的 DNS 解析器。
- **IP 选择优先级**：
  - 严格遵循 **RFC6724** 标准（通常默认 IPv6 优先级高于 IPv4）。
  - **注意**：由于 Go 的实现特性，它**不会**遵守 Linux 系统下的 `/etc/gai.conf` 配置文件（即你无法通过修改系统配置来让 Go 程序偏好 IPv4）。

**非 `AsIs` 模式（`UseIPv4` / `UseIPv6` / `Force...`）**

- **解析机制**：强制使用 **Xray 内置 DNS** 进行解析（只有当内置 DNS 模块未配置时，才会回退到系统 DNS）。
- **IP 选择优先级**：如果解析出多个 IP（例如多个 IPv6 地址），Xray 会**随机选择一个**作为目标 IP（简单的负载均衡），而不是按序选择。



**2.“软限制”与“硬限制”的区别**

当解析结果**不符合**你的设定时（例如：你设了 `...IPv6` 但域名只有 IPv4 地址）：

- **`Use` 开头（软限制，如 `UseIPv6`）**：
  - **行为**：尝试失败后，会自动**回落（Fallback）到 `AsIs` 模式**。
  - **结果**：最终可能还是走了 IPv4（由系统默认行为决定），连接通常能通，但可能没走你想要的协议栈。
- **`Force` 开头（硬限制，如 `ForceIPv6`）**：
  - **行为**：绝不妥协。如果解析不到对应的 IP，**直接中断连接**，抛出错误。
  - **结果**：连接失败。适用于“非 IPv6 不走”的严格隔离场景。



**3. ⚠️ 关键误区：关于 Happy Eyeballs（双栈竞速）**

很多人看到 `UseIPv4v6` 以为就是“自动竞速，谁快用谁”，这是**错误**的。

- **`UseIPv4v6` / `ForceIPv4v6`**：
  - 这只是代表“同时查询 A 和 AAAA 记录”。
  - **实际行为**：它拿到一堆 IP 后，会随机挑一个，或者简单地优先尝试某种地址，**并不是**真正的并发竞速。
  - **官方建议**：**不推荐**用这个选项来做回落。
- **真正的 Happy Eyeballs**：
  - **开启位置**：`streamSettings.sockopt.happyEyeballs`（设为 `true`）。
  - **生效条件**：
    1. 仅对 **TCP** 有效。
    2. `domainStrategy` **必须配置为非 `AsIs`**（建议配合 `UseIP`）。
  - **工作原理**：同时向 IPv4 和 IPv6 发起连接（有微小延迟），**谁先连通就用谁**。

**4.⚠️ UDP 流量的特殊性**

- **Freedom 协议的特殊性**：
  - 在使用 `Freedom` 出站发送 **UDP** 流量时（例如 QUIC/HTTP3、游戏、语音），Xray 会**无视** `sockopt.domainStrategy` 的设置。
  - **默认行为**：强制**偏好 IPv4**。
  - **后果**：即使你设置了 `UseIPv6`，UDP 流量可能依然会走 IPv4 出去，导致你的“全 IPv6”策略出现漏洞（除非你在 Routing 层直接屏蔽 QUIC/UDP）。



本方案用户出站使用 `ForceIPv6`：若目标无 AAAA（或 IPv6 不可达导致拨号失败），该次连接会失败，不会自动回退到 IPv4



完整Xray-Core Reality模板：

```
{
  "log": {
    "access": "none",
    "error": "none",
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPOnDemand",
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
        "user": [
          "user1@email.com"
        ],
        "ip": [
          "::/0"
        ],
        "outboundTag": "out-v6-1"
      },
      {
        "type": "field",
        "user": [
          "user2@email.com"
        ],
        "ip": [
          "::/0"
        ],
        "outboundTag": "out-v6-2"
      },
      {
        "type": "field",
        "user": [
          "user3@email.com"
        ],
        "ip": [
          "::/0"
        ],
        "outboundTag": "out-v6-3"
      },
      {
        "type": "field",
        "user": [
          "user4@email.com"
        ],
        "ip": [
          "::/0"
        ],
        "outboundTag": "out-v6-4"
      },
      {
        "type": "field",
        "user": [
          "user5@email.com"
        ],
        "ip": [
          "::/0"
        ],
        "outboundTag": "out-v6-5"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "::",
      "port": 443,
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {
        "clients": [
          {
            "id": "【用户1的UUID】",
            "email": "user1@email.com",
            "flow": "xtls-rprx-vision"
          },
          {
            "id": "【用户2的UUID】",
            "email": "user2@email.com",
            "flow": "xtls-rprx-vision"
          },
          {
            "id": "【用户3的UUID】",
            "email": "user3@email.com",
            "flow": "xtls-rprx-vision"
          },
          {
            "id": "【用户4的UUID】",
            "email": "user4@email.com",
            "flow": "xtls-rprx-vision"
          },
          {
            "id": "【用户5的UUID】",
            "email": "user5@email.com",
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
      "tag": "out-ipv4-only",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "ForceIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    },
    {
      "tag": "out-v6-1",
      "protocol": "freedom",
      "sendThrough": "【填入脚本生成的第1个IPv6地址】",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    },
    {
      "tag": "out-v6-2",
      "protocol": "freedom",
      "sendThrough": "【填入脚本生成的第2个IPv6地址】",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    },
    {
      "tag": "out-v6-3",
      "protocol": "freedom",
      "sendThrough": "【填入脚本生成的第3个IPv6地址】",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    },
    {
      "tag": "out-v6-4",
      "protocol": "freedom",
      "sendThrough": "【填入脚本生成的第4个IPv6地址】",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    },
    {
      "tag": "out-v6-5",
      "protocol": "freedom",
      "sendThrough": "【填入脚本生成的第5个IPv6地址】",
      "settings": {
        "domainStrategy": "ForceIPv6"
      }
    }
  ]
}
```

* **UUID**：是客户端用于建立连接的**唯一认证凭证（即密码）**，必须保密且与客户端配置完全一致。

- **Email**：仅作为服务端内部用于识别流量并匹配特定出口规则的**逻辑标识（即标签）**。

**⚠️ 注意**：此处的 `email` 字段与其字面意思无关，**无需填写真实邮箱**。它本质上是一个用于区分用户的**任意自定义字符串**。

**配置公式**： `Inbound 里的 email` **=** `流量的 Tag` **=** `Routing 规则里的 User`
