#!/usr/bin/env bash
#
# Hysteria2 一键对接脚本
#
# 作用：在 Hysteria2 节点服务器上安装并配置 Hysteria2，
#       通过面板的 /hysteria2/auth、/hysteria2/traffic 接口
#       实现用户认证与流量上报，并注册 systemd 服务与每分钟同步的 cron。
#
# 使用前请先在面板后台添加一个 Hysteria2 节点，记下节点 ID：
#   节点地址格式：<节点IP或域名>;port=443|sni=www.bing.com|insecure=1
#
# 用法示例：
#   sudo ./install-hysteria2.sh \
#     --panel-url http://1.2.3.4 \
#     --node-id 5
#
# 同机部署时会自动从 /opt/malio/config/.config.php 读取 muKey。
#
# 可选参数：
#   --mu-key <key>        面板 muKey（不填则尝试自动读取）
#   --port <port>         监听端口，默认 443
#   --sni <domain>        自签证书的 SNI，默认 www.bing.com
#   --stats-port <port>   流量统计接口端口，默认 9999
#   --stats-secret <str>  流量统计接口密钥，不填自动生成
#   --cert <path>         已有证书路径（配合 --key）
#   --key <path>          已有私钥路径（配合 --cert）
#   --download-url <url>  Hysteria2 二进制下载地址（GitHub 慢时可换镜像）
#   --skip-firewall       不自动执行 ufw 放行
#   --uninstall           卸载 Hysteria2 及本脚本写入的配置
#
set -euo pipefail

HY_VERSION="v2.12.3"
PANEL_URL=""
MU_KEY=""
NODE_ID=""
LISTEN_PORT="443"
SNI="www.bing.com"
STATS_PORT="9999"
STATS_SECRET=""
CERT_PATH=""
KEY_PATH=""
DOWNLOAD_URL=""
SKIP_FIREWALL="0"
UNINSTALL="0"

CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
TRAFFIC_SCRIPT="/opt/hysteria2-traffic.py"
CRON_FILE="/etc/cron.d/hysteria2-traffic"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,40p' "$0" | sed -n 's/^# \{0,1\}//p'
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel-url)     PANEL_URL="${2%/}"; shift 2 ;;
        --mu-key)        MU_KEY="$2"; shift 2 ;;
        --node-id)       NODE_ID="$2"; shift 2 ;;
        --port)          LISTEN_PORT="$2"; shift 2 ;;
        --sni)           SNI="$2"; shift 2 ;;
        --stats-port)    STATS_PORT="$2"; shift 2 ;;
        --stats-secret)  STATS_SECRET="$2"; shift 2 ;;
        --cert)          CERT_PATH="$2"; shift 2 ;;
        --key)           KEY_PATH="$2"; shift 2 ;;
        --download-url)  DOWNLOAD_URL="$2"; shift 2 ;;
        --skip-firewall) SKIP_FIREWALL="1"; shift ;;
        --uninstall)     UNINSTALL="1"; shift ;;
        -h|--help)       usage 0 ;;
        *) fail "未知参数：$1（用 --help 查看用法）" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || fail "请用 root 运行（sudo）"

if [[ "$UNINSTALL" == "1" ]]; then
    log "停止并卸载 Hysteria2"
    systemctl disable --now hysteria-server 2>/dev/null || true
    find /etc/cron.d -maxdepth 1 -name 'hysteria2-traffic' -delete 2>/dev/null || true
    find /opt -maxdepth 1 -name 'hysteria2-traffic.py' -delete 2>/dev/null || true
    find /etc/systemd/system -maxdepth 1 -name 'hysteria-server.service' -delete 2>/dev/null || true
    find /usr/local/bin -maxdepth 1 -name 'hysteria' -delete 2>/dev/null || true
    systemctl daemon-reload
    warn "已卸载。证书与配置文件保留在 ${CONFIG_DIR}，如需删除请手动处理。"
    exit 0
fi

[[ -n "$PANEL_URL" ]] || fail "缺少 --panel-url（面板地址，例如 http://1.2.3.4）"
[[ -n "$NODE_ID" ]] || fail "缺少 --node-id（面板后台 Hysteria2 节点的 ID）"

# muKey 自动读取（同机部署）
if [[ -z "$MU_KEY" && -f /opt/malio/config/.config.php ]]; then
    MU_KEY="$(grep -oE "\\\$_ENV\\['muKey'\\][[:space:]]*=[[:space:]]*'[^']+'" /opt/malio/config/.config.php | head -1 | sed -E "s/.*'([^']+)'.*/\1/")"
    [[ -n "$MU_KEY" ]] && log "已从面板配置读取 muKey"
fi
[[ -n "$MU_KEY" ]] || fail "缺少 --mu-key，且无法自动读取"

# 随机流量统计密钥
if [[ -z "$STATS_SECRET" ]]; then
    STATS_SECRET="hy2stats_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

case "$(uname -m)" in
    x86_64|amd64)   HY_ASSET="hysteria-linux-amd64" ;;
    aarch64|arm64)  HY_ASSET="hysteria-linux-arm64" ;;
    armv7l|armv7)   HY_ASSET="hysteria-linux-arm" ;;
    *) fail "不支持的架构：$(uname -m)" ;;
esac

if [[ -z "$DOWNLOAD_URL" ]]; then
    DOWNLOAD_URL="https://github.com/HyNetworks/hysteria/releases/download/app/${HY_VERSION}/${HY_ASSET}"
fi

log "下载 Hysteria2 ${HY_VERSION}（${HY_ASSET}）"
TMP_BIN="$(mktemp /tmp/hysteria-bin.XXXXXX)"
curl -fsSL --retry 3 -o "$TMP_BIN" "$DOWNLOAD_URL"
chmod +x "$TMP_BIN"
mv "$TMP_BIN" /usr/local/bin/hysteria
/usr/local/bin/hysteria version | head -6

# ------------------------------------------------------------------ 证书
mkdir -p "$CONFIG_DIR"
if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
    log "生成自签证书（SNI=${SNI}，客户端需 insecure=1）"
    CERT_PATH="${CONFIG_DIR}/server.crt"
    KEY_PATH="${CONFIG_DIR}/server.key"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" >/dev/null 2>&1
    chmod 600 "$KEY_PATH"
fi
[[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || fail "证书文件不存在：${CERT_PATH} / ${KEY_PATH}"

# ------------------------------------------------------------------ 配置
log "写入 ${CONFIG_FILE}"
cat > "$CONFIG_FILE" <<EOF
listen: :${LISTEN_PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

# 通过面板 HTTP 接口校验用户（auth 为用户 uuid 或连接密码）
auth:
  type: http
  http:
    url: ${PANEL_URL}/hysteria2/auth?key=${MU_KEY}&node_id=${NODE_ID}
    insecure: false

# 流量统计接口，仅监听本机，供面板定时拉取
trafficStats:
  listen: 127.0.0.1:${STATS_PORT}
  secret: ${STATS_SECRET}

# 非代理流量伪装成访问 Bing
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF
chmod 600 "$CONFIG_FILE"

# ------------------------------------------------------------------ systemd
log "注册 systemd 服务"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server
sleep 2
systemctl is-active hysteria-server >/dev/null || {
    journalctl -u hysteria-server -n 30 --no-pager || true
    fail "Hysteria2 启动失败，请查看上方日志"
}

# ------------------------------------------------------------------ 防火墙
if [[ "$SKIP_FIREWALL" != "1" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "放行 ufw ${LISTEN_PORT}/udp 与 ${LISTEN_PORT}/tcp"
    ufw allow "${LISTEN_PORT}/udp" >/dev/null || true
    ufw allow "${LISTEN_PORT}/tcp" >/dev/null || true
fi

# ------------------------------------------------------------------ 流量上报
log "写入流量上报脚本 ${TRAFFIC_SCRIPT}"
cat > "$TRAFFIC_SCRIPT" <<EOF
#!/usr/bin/env python3
"""拉取 Hysteria2 流量统计并上报到面板（由 install-hysteria2.sh 生成）。"""

import json
import sys
import urllib.error
import urllib.request

STATS_URL = "http://127.0.0.1:${STATS_PORT}/traffic?clear=1"
STATS_SECRET = "${STATS_SECRET}"
NODE_ID = ${NODE_ID}
PANEL_URL = "${PANEL_URL}/hysteria2/traffic?key=${MU_KEY}"


def main() -> int:
    try:
        request = urllib.request.Request(STATS_URL, headers={"Authorization": STATS_SECRET})
        with urllib.request.urlopen(request, timeout=10) as response:
            stats = json.load(response)
    except (urllib.error.URLError, ValueError) as exc:
        print(f"fetch stats failed: {exc}", file=sys.stderr)
        return 1

    data = []
    for user_id, item in stats.items():
        try:
            user_id = int(user_id)
        except (TypeError, ValueError):
            continue
        data.append({
            "user_id": user_id,
            "u": int(item.get("tx", 0)),
            "d": int(item.get("rx", 0)),
        })

    payload = json.dumps({"node_id": NODE_ID, "data": data}).encode()
    try:
        request = urllib.request.Request(
            PANEL_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
    except urllib.error.URLError as exc:
        print(f"report failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF
chmod 755 "$TRAFFIC_SCRIPT"

cat > "$CRON_FILE" <<EOF
* * * * * root /usr/bin/python3 ${TRAFFIC_SCRIPT} >/dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

# ------------------------------------------------------------------ 自检
log "自检：面板认证接口"
AUTH_RESULT="$(curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    -d '{"addr":"127.0.0.1:1","auth":"__selfcheck__","tx":0}' \
    "${PANEL_URL}/hysteria2/auth?key=${MU_KEY}&node_id=${NODE_ID}" || true)"
echo "  认证接口返回：${AUTH_RESULT:-（无响应，请检查面板地址与网络）}"

log "自检：流量上报"
/usr/bin/python3 "$TRAFFIC_SCRIPT" && echo "  流量上报 OK" || warn "流量上报失败，请检查面板地址"

echo
log "Hysteria2 部署完成"
cat <<EOF

面板节点地址请填写：
  <节点IP或域名>;port=${LISTEN_PORT}|sni=${SNI}|insecure=1

说明：
  1. 客户端订阅里的认证密码来自面板用户 uuid，无需在服务器上维护用户列表。
  2. 流量每分钟由 cron 上报，节点在线状态、用户用量会自动更新。
  3. 自签证书对应客户端 insecure=1；如配置了正式域名证书可去掉该参数。
  4. 查看日志：journalctl -u hysteria-server -f
EOF
