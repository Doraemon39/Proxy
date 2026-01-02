用sing-box搭建Shadowsocks2022协议的节点

1.安装Sing-box

```
curl -fsSL https://sing-box.app/install.sh | sh
```

2.开始搭建shadowsocks节点

```
sing-box generate rand --base64 32
```

```
nano /etc/sing-box/config.json
```

```
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": 8085,
      "network": ["tcp","udp"]
      "tcp_fast_open": true,
      "method": "2022-blake3-aes-256-gcm",
      "password": "这里填你生成的32位Base64密钥"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
```

3.设置成自启并启用

```
sudo systemctl enable --now sing-box
```

```
systemctl status sing-box
```

然后就可以使用了，URL获取。整体复制到命令行，回车运行：

```
(
    # 1. 设置配置文件路径
    CFG=/etc/sing-box/config.json

    # 2. 尝试自动获取公网IP (如果失败则显示 IP_ERROR)
    HOST_IP=$(curl -s https://api.ipify.org || echo "IP_ERROR")

    # 3. 提取关键字段
    M=$(sed -n 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -n1)
    P=$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CFG" | head -n1)
    PORT=$(sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' "$CFG" | head -n1)

    # 4. 检查提取是否成功
    if [ -z "$M" ] || [ -z "$P" ] || [ -z "$PORT" ]; then
        echo -e "\033[31m[错误] 无法从 $CFG 提取配置，请检查文件内容。\033[0m" >&2
        exit 1
    fi

    # 5. 生成 Base64 用户信息 (兼容写法)
    U=$(printf '%s:%s' "$M" "$P" | (base64 -w0 2>/dev/null || base64 | tr -d "\n") | tr '+/' '-_' | tr -d '=')

    # 6. 输出最终链接
    echo ""
    echo -e "\033[32m=== Shadowsocks 2022 链接 ===\033[0m"
    echo "ss://$U@$HOST_IP:$PORT#SS2022_Node"
    echo ""
)
```

