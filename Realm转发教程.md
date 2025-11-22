Realm转发教程

Realm作者：zhboner

Github地址：https://github.com/zhboner/realm

1.自己检查BBR的启动状态

2.安装realm

```
wget https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-gnu.tar.gz
```

```
tar -xzvf realm-x86_64-unknown-linux-gnu.tar.gz
```

```
chmod +x realm
```

```
sudo mv realm /usr/local/bin/
```

3.创建配置文件 

```
nano realm.toml
```

这是作者发的模板：https://github.com/zhboner/realm/blob/master/examples/full.toml

也可以按照我的来设置：

```
[log]
level = "warn"
output = "/root/realm.log"

#如果DNS异常才用这个
#[dns]
#mode = "ipv4_only"
#nameservers = ["8.8.8.8:53", "8.8.4.4:53"]  
#min_ttl = 300    
#max_ttl = 1800  
#cache_size = 128 

[network]
use_udp = true
tcp_timeout = 10
udp_timeout = 30
tcp_keepalive = 15

[[endpoints]]
listen = "[::]:端口"
remote = "[::]:端口"

[[endpoints]]
listen = "[::]:端口"
remote = "[::]:端口"
```

4.设置开机启动

nano /etc/systemd/system/realm.service

然后在里面写入

```
[Unit]
Description=Realm Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /root/realm.toml
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable realm
sudo systemctl restart realm
```

```
sudo systemctl status realm
```



