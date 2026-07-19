#!/bin/bash
# ============================================================
#  CTMANAGER PANEL - INSTALADOR
#  by CHARLY_TRICKS
#
#  Uso:
#    bash install-panel.sh
#    bash install-panel.sh --puerto 8088 --clave miclave
# ============================================================

set -uo pipefail

REPO="https://raw.githubusercontent.com/charly-tricks/ctmanager/main"
DIR="/opt/ctmanager-panel"
CFG_DIR="/etc/ctmanager/panel"
PUERTO=8088
CLAVE=""

V="\033[1;32m"; R="\033[1;31m"; A="\033[1;33m"; N="\033[0m"
msg()  { echo -e "  ${V}>${N} $*"; }
err()  { echo -e "  ${R}x${N} $*" >&2; }
warn() { echo -e "  ${A}!${N} $*"; }

[ "$(id -u)" -eq 0 ] || { err "Ejecutar como root"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --puerto) PUERTO="$2"; shift 2 ;;
        --clave)  CLAVE="$2"; shift 2 ;;
        *) err "Opcion desconocida: $1"; exit 2 ;;
    esac
done

[ -x /usr/local/bin/ctmanager-cli ] \
    || { err "Falta ctmanager-cli. Instalar install.sh primero."; exit 1; }

echo ""
echo -e "  ${V}CTMANAGER PANEL${N} - Instalador"
echo "  ────────────────────────────────────────"
echo ""

# ── Dependencias ─────────────────────────────────────────────
msg "Instalando Python y dependencias..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq python3 python3-pip curl >/dev/null 2>&1
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q python3 python3-pip curl >/dev/null 2>&1
elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm python python-pip curl >/dev/null 2>&1
fi

pip3 install --quiet --break-system-packages fastapi uvicorn 2>/dev/null \
    || pip3 install --quiet fastapi uvicorn 2>/dev/null \
    || { err "No se pudieron instalar fastapi y uvicorn"; exit 1; }
msg "Dependencias listas"

# ── Panel ────────────────────────────────────────────────────
mkdir -p "$DIR" "$CFG_DIR"
chmod 700 "$CFG_DIR"
wget -q -O "$DIR/panel.py" "$REPO/panel.py" \
    || { err "No se pudo descargar el panel"; exit 1; }
msg "Panel descargado"

# ── Contraseña ───────────────────────────────────────────────
if [ -z "$CLAVE" ]; then
    CLAVE=$(head -c 12 /dev/urandom | base64 | tr -d '+/=' | head -c 14)
    GENERADA=1
else
    GENERADA=0
fi

SAL=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
HASH=$(printf '%s' "${SAL}${CLAVE}" | sha256sum | cut -d' ' -f1)

cat > "$CFG_DIR/config.json" <<EOF
{
  "sal": "$SAL",
  "hash": "$HASH",
  "puerto": $PUERTO
}
EOF
chmod 600 "$CFG_DIR/config.json"

# ── Servicio ─────────────────────────────────────────────────
cat > /etc/systemd/system/ctmanager-panel.service <<EOF
[Unit]
Description=CTManager Panel Web
After=network.target

[Service]
Type=simple
Environment=CTMANAGER_PANEL_PORT=$PUERTO
ExecStart=/usr/bin/python3 $DIR/panel.py
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ctmanager-panel >/dev/null 2>&1
systemctl restart ctmanager-panel
sleep 3

IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "tu-ip")

echo ""
if systemctl is-active --quiet ctmanager-panel; then
    echo "  ────────────────────────────────────────"
    echo -e "  ${V}Panel instalado${N}"
    echo "  ────────────────────────────────────────"
    echo ""
    echo "  Dirección : http://$IP:$PUERTO"
    echo "  Contraseña: $CLAVE"
    echo ""
    if [ "$GENERADA" -eq 1 ]; then
        warn "Anotá esa contraseña ahora: no se vuelve a mostrar."
    fi
    echo ""
    echo "  Para cambiarla:"
    echo "    bash install-panel.sh --clave NUEVACLAVE"
    echo ""
    warn "El panel crea y borra cuentas del sistema."
    warn "Si podés, dejalo accesible solo desde tu IP:"
    echo "    ufw allow from TU.IP.AQUI to any port $PUERTO"
    echo "    ufw deny $PUERTO"
    echo ""
else
    err "El panel no arrancó."
    echo "  Ver el detalle con: journalctl -u ctmanager-panel -n 20"
fi
