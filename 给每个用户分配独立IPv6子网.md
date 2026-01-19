### IPv6独立子网分配

利用 VPS 配备的 /64 IPv6 子网，通过划定 5 个静态出口 IP，可达成**用户级流量隔离**。这不仅能降低因单一地址受损导致的业务中断风险，还能显著提升在高风控、单 IP 限制场景下的通过率。 **潜在挑战：** 无法防范针对子网段的屏蔽



#### 第一步：一键生成并绑定 IP

我们将使用自动化脚本来探测网络环境、生成随机 IP 并持久化挂载。

1. **创建脚本文件**

   ```
   nano ipv6-static-setup-fixed-final.bash
   ```

   ```
   将 ipv6-static-setup-fixed-final.bash 复制进去
   ```

   按 `Ctrl+O` 保存，再按 `Ctrl+X` 退出。

2. **赋予权限并执行**

   ```
   chmod +x ipv6-static-setup-fixed-final.bash
   bash ./ipv6-static-setup-fixed-final.bash
   ```

3. **查看生成的地址** 执行成功后，系统会自动配置好开机自启。你可以查看生成的 5 个地址：

   ```
   cat ~/random-ipv6
   ```



#### 第二步：配置 Xray-core 出站 (Outbounds)

你需要修改 Xray 的配置文件（通常是 `config.json`），利用 **`sendThrough`** 字段指定出口 IP。

**1. 修改 Outbounds（出站设置）** 在 `outbounds` 列表中添加 5 个对应的出口对象：

```
"outbounds": [
  {
    "tag": "out-v6-1",
    "protocol": "freedom",
    "sendThrough": "你的第1个IPv6地址" 
  },
  {
    "tag": "out-v6-2",
    "protocol": "freedom",
    "sendThrough": "你的第2个IPv6地址"
  },
  // ... 依此类推添加5个 ...
  {
    "tag": "direct",
    "protocol": "freedom"
  }
]
```

**2. 修改 Routing（路由设置）** 将不同的用户（或流量）分流到不同的 IP：

```
"routing": {
  "rules": [
    {
      "type": "field",
      "user": ["user1@email.com"], 
      "outboundTag": "out-v6-1" 
    },
    {
      "type": "field",
      "user": ["user2@email.com"], 
      "outboundTag": "out-v6-2" 
    }
  ]
}
```

