## VLESS Encryption

Vless Encryption是一个最新的加密协议，非伪装协议，不适合过墙使用，对标的是Shadowsocks协议

他比起SS协议，安全性更高，同时支持XUDP的特性。由于大部分转发，会屏蔽掉部分 UDP 流量，只允许 TCP 流量通过。XUDP 可以将 UDP “伪装”成 TCP 流量，从而穿透这些限制。

目前XUDP，虽说已经实现 FullCone NAT ，但其实并不完全适合游戏或语音，需要预计不久之后发布的PLUX和MUX增强，才能解决XUDP存在的一些性能问题

以上来源：https://github.com/XTLS/Xray-core/pull/5067


1. 自行检测和开启BBR，这一步跳过

2. 安装Xray

   ```
   apt update
   ```

    ```
   bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    ```

3. 配置文件config.json

   配置模板来源：https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP/config_server.jsonc

   

   可以按照我的步骤来：

   (1) 生成UUID，保存下来，待会使用

   ```
   /usr/local/bin/xray uuid
   ```

   (2) 生成X25519密钥对，保存下来，待会使用

   ```
   /usr/local/bin/xray x25519
   ```

   (3) 生成后量子密码 ML-KEM-768，会有一个seed和client，保存下来，待会使用

   ```
   /usr/local/bin/xray mlkem768
   ```

   

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
           "decryption": "mlkem768x25519plus.xorpub.600s.【粘贴刚刚生成的X25519公钥】.【粘贴刚刚生成ML-KEM-768的seed】"
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

   如果没有问题就可以使用了

   

4. 客户端配置(Clash mihomo)

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
     encryption: "mlkem768x25519plus.xorpub.0rtt.【粘贴刚刚生成的X25519私钥】.【粘贴刚刚生成ML-KEM-768的client】"
     network: tcp
   ```

   可分享的形式：

   ```
   vless://【粘贴你的UUID】@server:端口?encryption=mlkem768x25519plus.xorpub.0rtt.【粘贴刚刚生成的X25519私钥】.【粘贴刚刚生成ML-KEM-768的client】&security=none&flow=xtls-rprx-vision&packetEncoding=xudp&type=tcp#Vless Encryption
   ```

   

