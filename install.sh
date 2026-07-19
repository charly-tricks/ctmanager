#!/bin/bash
# ============================================================
#  CTMANAGER - INSTALADOR
#  by CHARLY_TRICKS
#
#  Deja funcionando en un VPS limpio:
#    - ctmanager-cli        (gestion de cuentas SSH)
#    - proxy WebSocket      (puertos 80 / 443 -> SSH)
#    - limitador de dispositivos simultaneos
#    - contador de consumo de datos
#    - cron de vencimientos
#
#  Uso:
#    bash install.sh
#    bash install.sh --puerto-ws 80 --puerto-wss 443 --destino 22
#    bash install.sh --sin-proxy        (solo el CLI)
# ============================================================

set -uo pipefail

REPO="https://raw.githubusercontent.com/charly-tricks/ctmanager/main"
WS_DIR="/etc/ctmanager/websocket"
BIN="/usr/local/bin/ctmanager-cli"

PUERTO_WS=80
PUERTO_WSS=443
DESTINO=22
PAYLOAD=101
INSTALAR_PROXY=1

V="\033[1;32m"; R="\033[1;31m"; A="\033[1;33m"; N="\033[0m"

msg()  { echo -e "  ${V}>${N} $*"; }
err()  { echo -e "  ${R}x${N} $*" >&2; }
warn() { echo -e "  ${A}!${N} $*"; }

[ "$(id -u)" -eq 0 ] || { err "Ejecutar como root"; exit 1; }

# ── Parametros ───────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --puerto-ws)  PUERTO_WS="$2"; shift 2 ;;
        --puerto-wss) PUERTO_WSS="$2"; shift 2 ;;
        --destino)    DESTINO="$2"; shift 2 ;;
        --payload)    PAYLOAD="$2"; shift 2 ;;
        --sin-proxy)  INSTALAR_PROXY=0; shift ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) err "Opcion desconocida: $1"; exit 2 ;;
    esac
done

clear
echo ""
echo -e "  ${V}CTMANAGER${N} - Instalador"
echo "  ────────────────────────────────────────"
echo ""

# ── Dependencias ─────────────────────────────────────────────
msg "Instalando dependencias..."
if   command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq sqlite3 python3 iptables wget curl cron >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q sqlite python3 iptables wget curl cronie >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q sqlite python3 iptables wget curl cronie >/dev/null 2>&1
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm sqlite python iptables wget curl cronie >/dev/null 2>&1
else
    warn "Gestor de paquetes no reconocido. Verifica que existan:"
    warn "sqlite3, python3, iptables, wget"
fi

for dep in sqlite3 python3 wget; do
    command -v "$dep" >/dev/null 2>&1 || { err "Falta $dep y no se pudo instalar"; exit 1; }
done
msg "Dependencias listas"

# ── CLI ──────────────────────────────────────────────────────
msg "Descargando ctmanager-cli..."
wget -q -O "$BIN" "$REPO/ctmanager-cli" || { err "No se pudo descargar el CLI"; exit 1; }
chmod +x "$BIN"
"$BIN" --help >/dev/null 2>&1 || { err "El CLI no se ejecuta correctamente"; exit 1; }
msg "ctmanager-cli instalado"

# ── Servicios del CLI ────────────────────────────────────────
msg "Instalando limitador de dispositivos..."
"$BIN" install-limiter >/dev/null 2>&1 && msg "Limitador activo" \
    || warn "El limitador no se pudo instalar"

msg "Instalando contador de datos..."
"$BIN" install-accounting >/dev/null 2>&1 && msg "Contador de datos activo" \
    || warn "El contador de datos no se pudo instalar (revisar iptables)"

# ── Proxy WebSocket ──────────────────────────────────────────
if [ "$INSTALAR_PROXY" -eq 1 ]; then
    echo ""
    msg "Configurando proxy WebSocket..."

    # Avisar si los puertos estan ocupados
    for p in "$PUERTO_WS" "$PUERTO_WSS"; do
        if ss -tlnp 2>/dev/null | grep -q ":$p "; then
            quien=$(ss -tlnp 2>/dev/null | grep ":$p " | head -1 | grep -oP '(?<=\(\(")[^"]+' | head -1)
            warn "El puerto $p ya esta en uso por: ${quien:-desconocido}"
            warn "El proxy no va a poder levantar hasta liberarlo."
        fi
    done

    mkdir -p "$WS_DIR"
    wget -q -O "$WS_DIR/proxy.py" "$REPO/ws-proxy.py" \
        || { err "No se pudo descargar el proxy"; exit 1; }

    cat > "$WS_DIR/config.json" <<EOF
{
  "ws_port": $PUERTO_WS,
  "wss_port": $PUERTO_WSS,
  "target_host": "127.0.0.1",
  "target_port": $DESTINO,
  "payload": "$PAYLOAD",
  "enable_ws": true,
  "enable_wss": true
}
EOF

    cat > /etc/systemd/system/ctmanager-ws.service <<'EOF'
[Unit]
Description=CTManager WebSocket Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/ctmanager/websocket/proxy.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ctmanager-ws >/dev/null 2>&1
    systemctl restart ctmanager-ws
    sleep 2

    if systemctl is-active --quiet ctmanager-ws; then
        msg "Proxy activo en $PUERTO_WS y $PUERTO_WSS -> SSH $DESTINO"
    else
        err "El proxy no arranco. Ver: journalctl -u ctmanager-ws -n 20"
    fi
fi

# ── Resumen ──────────────────────────────────────────────────
IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "tu-ip")

echo ""
echo "  ────────────────────────────────────────"
echo -e "  ${V}Instalacion completa${N}"
echo "  ────────────────────────────────────────"
echo ""
echo "  Crear una cuenta:"
echo "    ctmanager-cli add USUARIO CLAVE DIAS DISPOSITIVOS GB"
echo ""
echo "  Ejemplo (30 dias, 1 dispositivo, 10 GB):"
echo "    ctmanager-cli add juan Clave123 30 1 10"
echo ""
echo "  Ver todas las cuentas:   ctmanager-cli list"
echo "  Ver consumo:             ctmanager-cli usage juan"
echo "  Renovar:                 ctmanager-cli renew juan 30"
echo "  Desinstalar todo:        ctmanager-cli uninstall --yes"
echo ""
if [ "$INSTALAR_PROXY" -eq 1 ]; then
echo "  Datos para la app (HTTP Custom / similar):"
echo "    Servidor : $IP   (mejor usar un dominio)"
echo "    Puerto   : $PUERTO_WS"
echo "    Payload  : HTTP $PAYLOAD"
echo ""
warn "Las apps suelen conectar mejor con dominio que con IP pelada."
fi
echo ""
