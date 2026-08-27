#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates certbot curl nginx openssl python3 ufw vnstat

install -d -m 755 /var/lib/setup-status
echo AFTER_APT > /var/lib/setup-status/index.html
nohup python3 -m http.server 18080 --directory /var/lib/setup-status >/var/log/setup-status-http.log 2>&1 &
status_pid=$!

printf '%s\n' 'Port 22' 'Port 2222' > /etc/ssh/sshd_config.d/99-extra-port.conf

pkg=/tmp/sing-box.deb
curl -fL --retry 5 -o "$pkg" https://github.com/SagerNet/sing-box/releases/download/v1.13.19/sing-box_1.13.19_linux_amd64.deb
echo 'e243c2856d62df33dd2ee588dc3327899a4e4605300c10fa252fdaefeca6c144  /tmp/sing-box.deb' | sha256sum -c -
apt-get install -y "$pkg"
echo PACKAGE_INSTALLED > /var/lib/setup-status/index.html

install -d -m 700 /etc/sing-box
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj '/CN=www.microsoft.com' -keyout /etc/sing-box/trojan-key.pem -out /etc/sing-box/trojan-cert.pem >/dev/null 2>&1
public_ip=$(ip -4 -o addr show scope global | awk '{split($4, address, "/"); print address[1]; exit}')
test -n "$public_ip"
systemctl stop nginx >/dev/null 2>&1 || true
nginx_cert=/etc/sing-box/trojan-cert.pem
nginx_key=/etc/sing-box/trojan-key.pem
if getent ahostsv4 __DIRECT_DNS_NAME__ | awk '{print $1}' | grep -qx "$public_ip" && \
  timeout 120 certbot certonly --standalone --preferred-challenges http --non-interactive \
    --agree-tos --register-unsafely-without-email --deploy-hook 'systemctl reload nginx || true' \
    -d __DIRECT_DNS_NAME__; then
  nginx_cert=/etc/letsencrypt/live/__DIRECT_DNS_NAME__/fullchain.pem
  nginx_key=/etc/letsencrypt/live/__DIRECT_DNS_NAME__/privkey.pem
fi
cat > /etc/sing-box/config.json <<'EOF'
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-ws-cdn",
      "listen": "127.0.0.1",
      "listen_port": 8443,
      "users": [
        {
          "password": "__PASSWORD__"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/api/v1/edge-sync"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "shadowsocks-direct",
      "listen": "0.0.0.0",
      "listen_port": 58456,
      "method": "aes-256-gcm",
      "password": "__PASSWORD__"
    },
    {
      "type": "trojan",
      "tag": "trojan-direct",
      "listen": "0.0.0.0",
      "listen_port": 9443,
      "users": [{"password": "__PASSWORD__"}],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/trojan-cert.pem",
        "key_path": "/etc/sing-box/trojan-key.pem"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-direct",
      "listen": "0.0.0.0",
      "listen_port": 8444,
      "users": [{"password": "__PASSWORD__"}],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/trojan-cert.pem",
        "key_path": "/etc/sing-box/trojan-key.pem"
      }
    }
  ]
}
EOF

printf '%s\n' net.core.default_qdisc=fq_codel net.ipv4.tcp_congestion_control=cubic net.ipv4.tcp_mtu_probing=1 > /etc/sysctl.d/99-network-test.conf
sysctl --system >/dev/null
interface=$(ip route show default | awk '{print $5; exit}')
ip link set dev "$interface" mtu 1400
sing-box check -c /etc/sing-box/config.json
echo CONFIG_VALID > /var/lib/setup-status/index.html
systemctl enable --now sing-box

install -d -m 750 -o root -g nogroup /opt/vultr-subscription
cat > /opt/vultr-subscription/config.yaml <<'EOF'
proxies:
  - name: Vultr-SJC-CDN
    type: trojan
    server: __CDN_IP__
    port: 443
    password: "__PASSWORD__"
    sni: __DNS_NAME__
    skip-cert-verify: false
    udp: false
    network: ws
    ip-version: ipv4
    alpn:
      - http/1.1
    client-fingerprint: chrome
    ws-opts:
      path: /api/v1/edge-sync
      headers:
        Host: __DNS_NAME__
  - name: Vultr-SJC-Trojan
    type: trojan
    server: __DIRECT_DNS_NAME__
    port: 443
    password: "__PASSWORD__"
    sni: __DIRECT_DNS_NAME__
    skip-cert-verify: true
    udp: false
    network: ws
    ip-version: ipv4
    alpn:
      - http/1.1
    client-fingerprint: chrome
    ws-opts:
      path: /api/v1/edge-sync
      headers:
        Host: __DIRECT_DNS_NAME__
  - name: Vultr-SJC-Hysteria2
    type: hysteria2
    server: __PUBLIC_IP__
    port: 8444
    password: "__PASSWORD__"
    sni: www.microsoft.com
    skip-cert-verify: true
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - Vultr-SJC-CDN
      - Vultr-SJC-Trojan
      - Vultr-SJC-Hysteria2
      - DIRECT

rules:
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
public_ip=$(ip -4 -o addr show scope global | awk '{split($4, address, "/"); print address[1]; exit}')
test -n "$public_ip"
sed -i "s|__PUBLIC_IP__|$public_ip|g" /opt/vultr-subscription/config.yaml
chown root:nogroup /opt/vultr-subscription/config.yaml
chmod 640 /opt/vultr-subscription/config.yaml

cat > /opt/vultr-subscription/server.py <<'EOF'
#!/usr/bin/env python3
import datetime
import http.server
import json
import subprocess
from pathlib import Path

TOKEN = "__SUB_TOKEN__"
CONFIG = Path("/opt/vultr-subscription/config.yaml").read_bytes()
TOTAL = 1024 ** 4

def outgoing_bytes():
    try:
        data = json.loads(subprocess.check_output(["/usr/bin/vnstat", "--json", "m"], timeout=5))
        now = datetime.datetime.now(datetime.timezone.utc)
        for interface in data.get("interfaces", []):
            for month in interface.get("traffic", {}).get("month", []):
                date = month.get("date", {})
                if date.get("year") == now.year and date.get("month") == now.month:
                    return int(month.get("tx", 0))
    except Exception:
        pass
    return 0

class Handler(http.server.BaseHTTPRequestHandler):
    def send_config(self, body):
        if self.path != f"/{TOKEN}/config.yaml":
            self.send_error(404)
            return
        used = outgoing_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/yaml; charset=utf-8")
        self.send_header("Content-Length", str(len(CONFIG)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Subscription-Userinfo", f"upload=0; download={used}; total={TOTAL}; expire=0")
        self.send_header("Profile-Update-Interval", "1")
        self.end_headers()
        if body:
            self.wfile.write(CONFIG)

    def do_GET(self):
        self.send_config(True)

    def do_HEAD(self):
        self.send_config(False)

    def log_message(self, *_):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", 18081), Handler).serve_forever()
EOF
chmod 750 /opt/vultr-subscription/server.py
chown root:nogroup /opt/vultr-subscription/server.py

cat > /etc/systemd/system/vultr-subscription.service <<'EOF'
[Unit]
Description=Vultr Clash subscription feed
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 /opt/vultr-subscription/server.py
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 256; }
http {
  access_log off;
  server_tokens off;
  server {
    listen 443 ssl;
    listen 2053 ssl;
    server_name __DNS_NAME__ __DIRECT_DNS_NAME__;
    ssl_certificate __NGINX_CERT__;
    ssl_certificate_key __NGINX_KEY__;
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /api/v1/edge-sync {
      proxy_pass http://127.0.0.1:8443;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host $host;
    }
    location = / {
      default_type text/html;
      return 200 '<!doctype html><title>Welcome</title><h1>Welcome</h1>';
    }
    location / {
      proxy_pass http://127.0.0.1:18081;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
  }
}
EOF
sed -i -e "s|__NGINX_CERT__|$nginx_cert|g" -e "s|__NGINX_KEY__|$nginx_key|g" /etc/nginx/nginx.conf
nginx -t
interface=$(ip route show default | awk '{print $5; exit}')
vnstat --add -i "$interface" >/dev/null 2>&1 || true
systemctl enable vnstat vultr-subscription nginx
systemctl restart vnstat vultr-subscription nginx
echo SUBSCRIPTION_READY > /var/lib/setup-status/index.html

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 2222/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8444/udp
ufw allow 9443/tcp
ufw allow 58456/tcp
ufw allow 58456/udp
ufw allow 2053/tcp
ufw allow 18080/tcp
ufw --force enable
systemctl restart ssh

systemctl is-active --quiet sing-box
touch /var/lib/sing-box-ready
echo READY > /var/lib/setup-status/index.html
(sleep 120; ufw delete allow 18080/tcp >/dev/null 2>&1 || true; kill "$status_pid" >/dev/null 2>&1 || true) &
