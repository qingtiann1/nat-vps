#!/bin/bash
#===========================================================
# NAT VPS 一键代理搭建脚本
# 适用: Alpine / Debian 容器 (OpenRC / systemd)
# 节点: VLESS+Reality + VLESS+WS+TLS + HTTPS订阅
#===========================================================
set -e

#--- 配置变量（修改这里）---
DOMAIN="${1:-nat2jp.689998.xyz}"          # 你的域名
CF_TOKEN="${2:-cfut_gTIqPmZe1OpZWVWx4UJy9tJJRo281a6KvLeTC6h51e7b64f6}"

# 端口
REALITY_PORT=41267
WS_PORT=41268
SUB_PORT=41269

# Reality 伪装站点 (不要用微软)
FALLBACK_DOMAIN="www.apple.com"

echo "========================================"
echo " NAT VPS 代理一键安装"
echo " 域名: $DOMAIN"
echo " 节点端口: $REALITY_PORT / $WS_PORT"
echo " 订阅端口: $SUB_PORT (HTTPS)"
echo "========================================"

#--- 检测系统 ---
if [ -f /etc/alpine-release ]; then
    OS="alpine"
    echo "[*] 检测到 Alpine Linux"
elif [ -f /etc/debian_version ]; then
    OS="debian"
    echo "[*] 检测到 Debian $(cat /etc/debian_version)"
else
    echo "[!] 不支持的系统"; exit 1
fi

#--- 安装依赖 ---
echo "[*] 安装依赖..."
if [ "$OS" = "alpine" ]; then
    apk update >/dev/null 2>&1
    apk add curl wget unzip socat python3 openssl >/dev/null 2>&1
else
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl wget unzip socat python3 openssl >/dev/null 2>&1
fi

#--- 安装 Xray ---
if [ ! -f /usr/local/bin/xray ]; then
    echo "[*] 下载 Xray..."
    XRAY_VER="v26.3.27"
    DOWNLOAD_OK=false
    for url in \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        "https://gh-proxy.com/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        "https://mirror.ghproxy.com/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip" \
        "https://download.fastgit.org/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"; do
        echo "  尝试: $url"
        rm -f /tmp/xray.zip
        curl -sL --connect-timeout 10 --max-time 120 -o /tmp/xray.zip "$url" || continue
        # 验证：真正的xray.zip约21MB，小于1MB的肯定是假文件
        SIZE=$(stat -c%s /tmp/xray.zip 2>/dev/null || stat -f%z /tmp/xray.zip 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 1000000 ]; then
            DOWNLOAD_OK=true
            break
        else
            echo "  文件太小($SIZE bytes)，跳过"
        fi
    done
    if [ "$DOWNLOAD_OK" = false ]; then
        echo "[!] Xray 下载失败，请手动上传 xray 到 /usr/local/bin/xray"
        exit 1
    fi
    cd /tmp && unzip -q -o xray.zip
    cp xray /usr/local/bin/xray
    chmod +x /usr/local/bin/xray

    # 下载 geo 数据（多镜像+大小验证）
    mkdir -p /usr/local/share/xray
    for url in \
        "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        "https://ghproxy.net/https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        "https://gh-proxy.com/https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"; do
        rm -f /usr/local/share/xray/geoip.dat
        curl -sL --connect-timeout 10 --max-time 120 -o /usr/local/share/xray/geoip.dat "$url" || continue
        SIZE=$(stat -c%s /usr/local/share/xray/geoip.dat 2>/dev/null || echo 0)
        [ "$SIZE" -gt 1000000 ] && break
        echo "  geoip 太小($SIZE)，重试..."
    done
    for url in \
        "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        "https://ghproxy.net/https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        "https://gh-proxy.com/https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"; do
        rm -f /tmp/dlc.dat
        curl -sL --connect-timeout 10 --max-time 120 -o /tmp/dlc.dat "$url" || continue
        SIZE=$(stat -c%s /tmp/dlc.dat 2>/dev/null || echo 0)
        [ "$SIZE" -gt 500000 ] && break
        echo "  dlc 太小($SIZE)，重试..."
    done
    [ -f /tmp/dlc.dat ] && mv /tmp/dlc.dat /usr/local/share/xray/geosite.dat
    echo "[*] Xray $(/usr/local/bin/xray version 2>&1 | head -1)"
else
    echo "[*] Xray 已安装"
fi

#--- 创建目录 ---
mkdir -p /usr/local/etc/xray/certs /usr/local/share/xray /var/log/xray

#--- 生成密钥 ---
echo "[*] 生成密钥..."
/usr/local/bin/xray x25519 > /tmp/reality_keys.txt
PRIVKEY=$(grep PrivateKey /tmp/reality_keys.txt | head -1 | cut -d' ' -f2)
PUBKEY=$(grep PublicKey /tmp/reality_keys.txt | head -1 | rev | cut -d' ' -f1 | rev)
UUID_REALITY=$(/usr/local/bin/xray uuid)
UUID_WS=$(/usr/local/bin/xray uuid)
SHORT_ID=$(openssl rand -hex 8)
WS_PATH="/$(openssl rand -hex 12)"

echo "  PrivateKey: $PRIVKEY"
echo "  PublicKey:  $PUBKEY"
echo "  ShortId:    $SHORT_ID"
echo "  WS Path:    $WS_PATH"

#--- 写 Xray 配置 ---
cat > /usr/local/etc/xray/config.json << XEOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "reality",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID_REALITY", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$FALLBACK_DOMAIN:443",
          "serverNames": ["$FALLBACK_DOMAIN", "apple.com"],
          "privateKey": "$PRIVKEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    },
    {
      "tag": "ws-tls",
      "port": $WS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID_WS"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/usr/local/etc/xray/certs/fullchain.crt",
            "keyFile": "/usr/local/etc/xray/certs/private.key"
          }]
        },
        "wsSettings": {"path": "$WS_PATH"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}]
  }
}
XEOF

# 验证配置
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1 | tail -1

#--- 申请 TLS 证书 ---
echo "[*] 申请 TLS 证书..."
if [ ! -f /root/.acme.sh/acme.sh ]; then
    curl -sL --connect-timeout 10 https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh | sh -s email=admin@${DOMAIN#*.} >/dev/null 2>&1
fi
export CF_Token="$CF_TOKEN"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" 2>&1 | tail -3
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /usr/local/etc/xray/certs/private.key \
    --fullchain-file /usr/local/etc/xray/certs/fullchain.crt 
    --reloadcmd "(systemctl restart xray sub-server 2>/dev/null; rc-service xray restart 2>/dev/null; rc-service sub-server restart 2>/dev/null)" 2>&1 | tail -1
echo "[*] 证书安装完成（ZeroSSL 90天有效，acme.sh cron自动续期+重启服务）"
WS_LINK="vless://${UUID_WS}@${DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&path=${WS_PATH}#$(echo $DOMAIN | cut -d. -f1)-ws-tls"

echo "$REALITY_LINK" > /usr/local/etc/xray/reality_link.txt
echo "$WS_LINK" > /usr/local/etc/xray/ws_link.txt
echo -e "${REALITY_LINK}\n${WS_LINK}" | base64 -w 0 > /usr/local/etc/xray/sub.txt

#--- 创建订阅响应脚本 ---
cat > /usr/local/bin/sub-resp.sh << 'SUBRESP'
#!/bin/bash
read -r method path version
BODY=$(cat /usr/local/etc/xray/sub.txt)
LEN=${#BODY}
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$LEN" "$BODY"
SUBRESP
chmod +x /usr/local/bin/sub-resp.sh

#--- 注册服务 ---
if [ "$OS" = "alpine" ]; then
    # OpenRC
    cat > /etc/init.d/xray << 'XRINIT'
#!/sbin/openrc-run
name=xray
description="Xray Service"
command=/usr/local/bin/xray
command_args="run -config /usr/local/etc/xray/config.json"
command_background=true
pidfile=/run/xray.pid
depend() { need net; }
XRINIT
    chmod +x /etc/init.d/xray

    cat > /etc/init.d/sub-server << 'SUBINIT'
#!/sbin/openrc-run
name=sub-server
description="Subscription HTTPS Server"
command=/usr/bin/socat
command_args="OPENSSL-LISTEN:SUB_PORT_PLACEHOLDER,cert=/usr/local/etc/xray/certs/fullchain.crt,key=/usr/local/etc/xray/certs/private.key,reuseaddr,fork,verify=0 EXEC:/usr/local/bin/sub-resp.sh"
command_background=true
pidfile=/run/sub-server.pid
depend() { need net; }
SUBINIT
    sed -i "s/SUB_PORT_PLACEHOLDER/$SUB_PORT/" /etc/init.d/sub-server
    chmod +x /etc/init.d/sub-server

    rc-update add xray default 2>/dev/null
    rc-update add sub-server default 2>/dev/null
    rc-service xray restart 2>/dev/null
    rc-service sub-server restart 2>/dev/null
else
    # systemd
    cat > /etc/systemd/system/xray.service << XRSVC
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
XRSVC

    cat > /etc/systemd/system/sub-server.service << SUBSVC
[Unit]
Description=Subscription HTTPS Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/socat OPENSSL-LISTEN:${SUB_PORT},cert=/usr/local/etc/xray/certs/fullchain.crt,key=/usr/local/etc/xray/certs/private.key,reuseaddr,fork,verify=0 EXEC:/usr/local/bin/sub-resp.sh
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
SUBSVC

    systemctl daemon-reload
    systemctl enable xray sub-server 2>/dev/null
    systemctl restart xray sub-server 2>/dev/null
fi

sleep 2

#--- 验证 ---
echo ""
echo "========================================"
echo "  安装完成！"
echo "========================================"
echo ""
echo "📡 Reality 节点:"
echo "  $REALITY_LINK"
echo ""
echo "📡 WS+TLS 节点:"
echo "  $WS_LINK"
echo ""
echo "🔗 订阅链接:"
echo "  https://${DOMAIN}:${SUB_PORT}/"
echo ""
echo "========================================"

# 检查端口
if command -v ss >/dev/null 2>&1; then
    echo "监听端口:"
    ss -tlnp | grep -E "$REALITY_PORT|$WS_PORT|$SUB_PORT" 2>/dev/null || true
elif command -v netstat >/dev/null 2>&1; then
    echo "监听端口:"
    netstat -tlnp | grep -E "$REALITY_PORT|$WS_PORT|$SUB_PORT" 2>/dev/null || true
fi
