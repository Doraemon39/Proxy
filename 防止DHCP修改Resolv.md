```
sudo nano /usr/local/bin/dns_guardian.sh
```

```
#!/bin/bash

set -euo pipefail # 脚本更严格模式

# --- 配置 ---
RESOLV_FILE="/etc/resolv.conf"
DESIRED_DNS_SERVERS=("8.8.8.8" "8.8.4.4" "1.1.1.1" "2001:4860:4860::8888" "2001:4860:4860::8844")
CONNECTIVITY_CHECK_HOST="1.1.1.1"

# --- 1. 网络连通性检查 ---
if ! ping -c 1 -W 3 "${CONNECTIVITY_CHECK_HOST}" &> /dev/null; then
    echo "网络不通，跳过本次DNS检查以防误判。"
    exit 0
fi

#
# --- 关键修正：一次性构建理想的 resolv.conf 内容 ---
# 直接使用printf循环处理整个数组，确保每个条目都正确地以换行符结尾。
#
IDEAL_CONTENT=$(printf "nameserver %s\n" "${DESIRED_DNS_SERVERS[@]}")

# --- 3. 对比当前内容与理想内容 ---
CURRENT_CONTENT=$(cat "${RESOLV_FILE}" 2>/dev/null || true)
CURRENT_NORMALIZED=$(echo -e "${CURRENT_CONTENT}" | grep "nameserver" | sort | uniq | xargs)
IDEAL_NORMALIZED=$(echo -e "${IDEAL_CONTENT}"   | grep "nameserver" | sort | uniq | xargs)

if [[ "${CURRENT_NORMALIZED}" == "${IDEAL_NORMALIZED}" ]]; then
    echo "resolv.conf 内容正常，无需修改。"
    exit 0
fi

# --- 4. 如果需要修改，则执行安全的文件写入操作 ---
echo "检测到 resolv.conf 内容异常，正在执行修复..."

if ! lsattr "${RESOLV_FILE}" 2>/dev/null | grep -q "i"; then
    # 文件未被锁定，可以写入
    if printf "%s" "${IDEAL_CONTENT}" | tee "${RESOLV_FILE}" > /dev/null; then
        echo "resolv.conf 已成功修复。"
    else
        echo "错误：无法写入到 ${RESOLV_FILE}！请检查权限。"
        exit 1
    fi
else
    # 文件被锁定了
    echo "错误：${RESOLV_FILE} 的目标文件被锁定 (chattr +i)，无法修改。请先手动解锁。"
    exit 1
fi

exit 0
```

```
sudo chmod +x /usr/local/bin/dns_guardian.sh
```

```
sudo nano /etc/systemd/system/dns-guardian.service
```

```
[Unit]
Description=Guardian for /etc/resolv.conf to ensure correct DNS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns_guardian.sh
ReadWritePaths=/etc/resolv.conf
ProtectSystem=full
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```
sudo nano /etc/systemd/system/dns-guardian.timer
```

```
[Unit]
Description=Run dns-guardian service every 3 hours and on boot

[Timer]
OnBootSec=2min
OnUnitActiveSec=3h
RandomizedDelaySec=5m
Persistent=true
Unit=dns-guardian.service

[Install]
WantedBy=timers.target
```

```
sudo systemctl daemon-reload
```

```
sudo systemctl enable --now dns-guardian.timer
```



验证：手动执行脚本是否报错：

```
sudo /usr/local/bin/dns_guardian.sh
```

检查计时器状态：

```
systemctl status dns-guardian.timer
```

