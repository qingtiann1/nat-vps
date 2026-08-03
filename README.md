# NAT VPS 一键代理脚本

适用 Alpine / Debian 容器 VPS，一条命令搭建 **VLESS+Reality + VLESS+WS+TLS + HTTPS订阅**。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/qingtiann1/nat-vps/main/nat-setup.sh) 你的域名 你的CF_Token
```

**示例：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/qingtiann1/nat-vps/main/nat-setup.sh) nat5hkt.689998.xyz cfut_xxxxxxxxxxxx
```

## 运行后输出

- Reality 节点链接
- WS+TLS 节点链接
- HTTPS 订阅地址

## 端口规划

| 端口 | 用途 |
|------|------|
| 41267 | VLESS + XTLS + Reality |
| 41268 | VLESS + WebSocket + TLS |
| 41269 | HTTPS 订阅 |
| 51266 | SSH 管理 |

## 前置条件

1. VPS 端口已映射：41267-41270 → 内网对应端口
2. Cloudflare DNS 解析到 VPS 公网 IP
3. Cloudflare API Token（用于申请 Let's Encrypt 证书）

## 节点信息

- Reality 伪装站：`www.apple.com`（不要用微软）
- 订阅走 HTTPS（NAT 环境不转发纯 HTTP 流量）
- 证书自动续期（acme.sh + Cloudflare DNS）

## 适配系统

| 系统 | Init | 测试 |
|------|------|------|
| Alpine 3.21 | OpenRC | ✅ |
| Debian 11/12 | systemd | ✅ |
