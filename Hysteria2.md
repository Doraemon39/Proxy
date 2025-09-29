Hysteria2 项目官网：https://v2.hysteria.network/

由于Hysteria2自带拥塞控制，所以不需要启动BBR，所以跳过该步骤



1.安装Hysteira

```
bash <(curl -fsSL https://get.hy2.sh/)
```

2.服务器配置

因为Hysteira2的TLS有两种形式：自签TLS证书和ACME证书，所以以下是不同TLS形式的搭建方法。



2.1 自签TLS证书的搭建方法

```
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=www.bing.com" -days 36500
```

```
sudo chown hysteria /etc/hysteria/server.key
```

```
sudo chown hysteria /etc/hysteria/server.crt
```

```
nano /etc/hysteria/config.yaml
```

```
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: 自己设置一个密码

bandwidth:
  up: 1000 mbps
  down: 1000 mbps

ignoreClientBandwidth: false

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,8000-9000
  udpPorts: all

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
```

```
注意：配置里的bandwidth需设置成，服务器能达到的最大带宽
```

```
systemctl restart hysteria-server.service
```

```
systemctl enable hysteria-server.service
```

```
systemctl status hysteria-server.service
```

然后节点写成以下形式即可使用（不标准，需根据不同类型的订阅管理，自行调整）：

```
hysteria2://密码@IP:端口?&insecure=1&sni=www.bing.com&up=100&down=100#节点名称
```

需要注意以下几点

```
1. 客户端的sni 需设置为 masquerade 里的 url 伪装域名
2. 必须客户端设置限速 Up&down ，才能使用 Hysteira 自有的拥塞控制算法。若客户端不设置，将默认使用传统BBR
3. insecure = 1 为跳过验证
```



但并不完美：

```
因为使用的是自签证书，很容易被中间人拦截。为了防止这种情况，需要用到证书指纹 FingerPrint
```

```
openssl x509 -in /etc/hysteria/server.crt -noout -fingerprint -sha256 | tr -d ':'
```

```
你会得到类似于：
SHA256 Fingerprint=xxxxxxxxxxxx
```

最后，节点写成以下形式即可（不标准，需根据不同类型的订阅管理，自行调整）：

```
hysteria2://密码@IP:端口?&insecure=0&sni=www.bing.com&up=100&down=100&alpn=h3&fingerprint=xxxxxxxxx#节点名称
```

```
insecure = 0 不跳过证书验证，对比服务器的证书指纹来匹配连接是否安全
```



2.2 ACME证书搭建

自签证书最大的问题是：SNI与证书域名，虽然匹配，但证书并非权威CA颁发，而是一个自签证书，DPI会识别成证书欺骗和域名冒充的行为，伪装性反而是变差了



ACME证书则是由公共、可信的CA颁发，更为可靠

```
nano /etc/hysteria/config.yaml
```

```
listen: :443

acme:
  domains:
    - your.domain.net
  email: your@email.com

auth:
  type: password
  password: 自己设置一个密码

bandwidth:
  up: 1000 mbps
  down: 1000 mbps

ignoreClientBandwidth: false

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,8000-9000
  udpPorts: all

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
```



在有些NAT VPS或者NAT LXC，可能会因为80/443端口被禁用，导致申请证书失败，所以需要用到 ACME DNS

不同的DNS服务商有不同的配置方法，以下是CloudFlare的配置：

```
listen: :443

acme:
  domains:
    - "*.example.com"
  email: your@email.address
  type: dns
  dns:
    name: cloudflare
    config:
      cloudflare_api_token: xxxxxx需自行去CloudFlare申请

auth:
  type: password
  password: 自己设置一个密码

bandwidth:
  up: 1000 mbps
  down: 1000 mbps

ignoreClientBandwidth: false

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
  tcpPorts: 80,443,8000-9000
  udpPorts: all

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
```

```
systemctl restart hysteria-server.service
```

```
systemctl enable hysteria-server.service
```

```
systemctl status hysteria-server.service
```

然后可以使用了

```
hysteria2://密码@IP:端口?&insecure=0&sni=你的域名&up=100&down=100&alpn=h3#节点名称
```



端口跳跃

```
中国用户有时报告运营商会阻断或限速 UDP 连接。不过，这些限制往往仅限单个端口。端口跳跃可用作此情况的解决方法
```

```
Hysteria 服务端并不能同时监听多个端口，因此不能在服务器端使用上面的格式作为监听地址。需要配合 iptables 或 nftables 的 DNAT 将端口转发到服务器的监听端口。
```

```
apt update && sudo apt install nftables -y
```

```
systemctl enable --now nftables
```

```
nano /etc/nftables.conf
```

 在 flush ruleset 的下方添加定义：

```
define INGRESS_INTERFACE="eth0"
define PORT_RANGE=20000-50000
define HYSTERIA_SERVER_PORT=443
```

然后在最底部添加：

```
table inet hysteria_porthopping {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname $INGRESS_INTERFACE udp dport $PORT_RANGE counter redirect to :$HYSTERIA_SERVER_PORT
  }
}
```

```
这个示例中，服务器监听 443 端口，但客户端可以通过 20000-50000 范围内的任何端口连接。
```

```
systemctl restart nftables
```



配置文件改成以下形式就可以使用：

```
hysteria2://密码@IP:20000-50000?&insecure=0&sni=你的域名&up=100&down=100&alpn=h3#节点名称
```

```
注意：
1. 如果用acme dns申请失败的话，大概率是本机resolv.conf的问题，换成1.1.1.1就能解决
2. 如果使用ACME的方法申请证书，防火墙务必不要屏蔽80端口入站，否则使用ACME DNS的方法申请会比较好
```

