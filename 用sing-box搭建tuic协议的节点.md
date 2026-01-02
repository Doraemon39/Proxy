用sing-box搭建tuic协议的节点

1. 安装Sing-box

   ```
   wget https://github.com/SagerNet/sing-box/releases/download/v1.11.13/sing-box-1.11.13-linux-amd64.tar.gz
   ```

   ```
   tar -xzvf sing-box-1.11.13-linux-amd64.tar.gz
   ```

   ```
   rm sing-box-1.11.13-linux-amd64.tar.gz
   ```

   ```
   mv ./sing-box-1.11.13-linux-amd64/sing-box /usr/local/bin/
   ```

   ```
   rm -rf ./sing-box-1.11.13-linux-amd64
   ```

   2.配置ACME证书

   ```
   apt-get install certbot
   ```

   ```
   apt-get install python3-certbot-dns-cloudflare
   ```

   ```
   mkdir /root/.certbot
   ```

   ```
   nano /root/.certbot/cloudflare.ini
   ```

   在里面输入：

   ```
   dns_cloudflare_email = 你的CloudFlare注册时的邮箱
   dns_cloudflare_api_key = 你的API密钥(Gloabal API Key)
   ```

   ```
   chmod 600 /root/.certbot/cloudflare.ini
   ```

   ```
   sudo certbot certonly \
     --dns-cloudflare \
     --dns-cloudflare-credentials ~/.certbot/cloudflare.ini \
     -d 你的域名
   ```

   如果提示：
   ```
   Saving debug log to /var/log/letsencrypt/letsencrypt.log
   Enter email address (used for urgent renewal and security notices)
    (Enter 'c' to cancel): 
   
   证明你有申请过，我们跳过提示邮箱，输入以下命令：
   ```

   ```
   sudo certbot certonly \
     --dns-cloudflare \
     --dns-cloudflare-credentials ~/.certbot/cloudflare.ini \
     --non-interactive \
     --agree-tos \
     --register-unsafely-without-email \
     -d 你的域名
   ```

   ```
   然后就会获得一个期限为90天的证书，且会自动续期
   Certbot 已创建定时任务（通常位于 /etc/cron.d/certbot）
   
   Certificate is saved at: /etc/letsencrypt/live/你的域名/fullchain.pem
   Key is saved at:         /etc/letsencrypt/live/你的域名/privkey.pem
   ```

   3.开始搭建TUIC节点

   ```
   apt install uuid-runtime
   ```

   ```
   echo "认证信息已随机生成："
   echo "UUID: $(uuidgen || cat /proc/sys/kernel/random/uuid)"
   echo "密码: $(tr -dc 'A-Za-z0-9!@#$%^&*()_+=' < /dev/urandom | head -c 16)"
   ```

   ```
   nano /root/sing-box-config.json
   ```

   在里面输入

   ```
   {
     "log": {
       "level": "info",
       "timestamp": true
     },
     "inbounds": [
       {
         "type": "tuic",
         "tag": "tuic-in",
         "listen": "::",
         "listen_port": 443,  // 建议用 443/8443（避免 QoS）
         "users": [
           {
             "uuid": "YOUR_UUID",    // 生成 UUID：`uuidgen`
             "password": "STRONG_PWD" // 强密码（字母+数字+符号）
           }
         ],
         "congestion_control": "bbr",  // 推荐 bbr/cubic
         "tls": {
           "enabled": true,
           "alpn": ["h3"],             // 必须为 h3
           "certificate_path": "/etc/letsencrypt/live/你的域名/fullchain.pem",  // 证书路径
           "key_path": "/etc/letsencrypt/live/你的域名/privkey.pem"             // 私钥路径
         }
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

   然后sing-box run -c /root/sing-box-config.json 进行调试，若没有报错，即可设置成服务自启

   4.设置成自启

   ```
   sudo nano /etc/systemd/system/sing-box.service
   ```

   然后在里面写入

   ```
   [Unit]
   Description=Sing-box Service
   After=network.target
   Wants=network-online.target
   
   [Service]
   Type=simple
   ExecStart=/usr/local/bin/sing-box run -c /root/sing-box-config.json
   Restart=always
   RestartSec=3
   User=root
   CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
   AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
   LimitNOFILE=infinity
   
   [Install]
   WantedBy=multi-user.target
   ```

   ```
   sudo systemctl daemon-reload
   systemctl enable sing-box
   systemctl restart sing-box
   ```

   ```
   systemctl status sing-box
   ```

   然后就可以使用了

   ```
   tuic://uuid:密码@你的域名:你的端口?sni=你的域名&alpn=h3&congestion_control=bbr&udp_relay_mode=native&allow_insecure=0#TUIC-节点
   ```

   密码要记得用urlEncode编码转换，网上找个在线转换工具就行，如果觉得麻烦的话，就只弄纯数字+纯字母的密码就行
