#!/bin/bash
# ============================================================
#   CTMANAGER - by CHARLY_TRICKS
#   Versión 1.0
#   Todo en uno: Hysteria, WebSocket, SOCKS, BadVPN,
#   SlowDNS, Psiphon, Brook, Dropbear, Stunnel, OpenVPN
# ============================================================

# ── Colores ──────────────────────────────────────────────────
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Rutas base ────────────────────────────────────────────────
BASE_DIR="/etc/ctmanager"
SCRIPTS_DIR="$BASE_DIR/scripts"
LOGS_DIR="$BASE_DIR/logs"
CONFIG_DIR="$BASE_DIR/config"
MANAGER_PATH="/usr/local/bin/ctmanager"
GITHUB_RAW="https://raw.githubusercontent.com/charly-tricks/hysteria-manager/main"

# ── Verificar root ────────────────────────────────────────────
if [ "$(whoami)" != "root" ]; then
    echo -e "${RED}Error: Este script debe ejecutarse como root.${NC}"
    exit 1
fi

# ── Logger ────────────────────────────────────────────────────
log() {
    mkdir -p "$LOGS_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGS_DIR/ctmanager.log"
}

# ── Detectar OS y gestor de paquetes ─────────────────────────
detectar_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    else
        OS="unknown"
    fi
    if command -v apt-get &>/dev/null; then
        PKG="apt"
    elif command -v dnf &>/dev/null; then
        PKG="dnf"
    elif command -v yum &>/dev/null; then
        PKG="yum"
    elif command -v pacman &>/dev/null; then
        PKG="pacman"
    else
        PKG="unknown"
    fi
}

# ── Instalador universal de paquetes ─────────────────────────
pkg_install() {
    detectar_os
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>/dev/null
            apt-get install -y -qq "$@" 2>/dev/null
            ;;
        dnf)
            dnf install -y epel-release 2>/dev/null || true
            dnf install -y "$@" 2>/dev/null
            ;;
        yum)
            yum install -y epel-release 2>/dev/null || true
            yum install -y "$@" 2>/dev/null
            ;;
        pacman)
            pacman -Sy --noconfirm "$@" 2>/dev/null
            ;;
        *)
            echo -e "${RED}  [!] Gestor de paquetes no detectado.${NC}"
            ;;
    esac
}

# ── Nombre de paquetes por distro ─────────────────────────────
pkg_name() {
    detectar_os
    case "$1" in
        sqlite3)      [ "$PKG" = "apt" ] && echo "sqlite3" || echo "sqlite" ;;
        cron)         [ "$PKG" = "apt" ] && echo "cron" || echo "cronie" ;;
        nettools)     echo "net-tools" ;;
        golang)       [ "$PKG" = "apt" ] && echo "golang-go" || echo "golang" ;;
        build)        [ "$PKG" = "apt" ] && echo "build-essential" || echo "gcc make cmake" ;;
        stunnel)      [ "$PKG" = "apt" ] && echo "stunnel4" || echo "stunnel" ;;
        dropbear)     echo "dropbear" ;;
        certbot)      echo "certbot" ;;
        certbot_nginx)[ "$PKG" = "apt" ] && echo "python3-certbot-nginx" || echo "python3-certbot-nginx" ;;
        easyrsa)      [ "$PKG" = "apt" ] && echo "easy-rsa" || echo "easy-rsa" ;;
        ufw)          [ "$PKG" = "apt" ] && echo "ufw" || echo "" ;;
        *)            echo "$1" ;;
    esac
}

# ── Nombre del servicio stunnel por distro ────────────────────
stunnel_svc() {
    detectar_os
    [ "$PKG" = "apt" ] && echo "stunnel4" || echo "stunnel"
}

# ── Habilitar crond en no-Debian ─────────────────────────────
habilitar_cron() {
    detectar_os
    if [ "$PKG" != "apt" ]; then
        systemctl enable crond 2>/dev/null && systemctl start crond 2>/dev/null || true
    fi
}

# ── Instalar dependencias base ────────────────────────────────
instalar_deps_base() {
    detectar_os
    pkg_install curl wget openssl lsof screen jq python3 python3-pip \
        "$(pkg_name sqlite3)" "$(pkg_name cron)" "$(pkg_name nettools)"
    habilitar_cron
    pip3 install websockets 2>/dev/null || pip3 install websockets --break-system-packages 2>/dev/null || true
}

# ── Notificación Telegram ─────────────────────────────────────
TG_CONFIG="$CONFIG_DIR/telegram.conf"
send_telegram() {
    local mensaje="$1"
    if [ -f "$TG_CONFIG" ]; then
        source "$TG_CONFIG"
        if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
                -d "chat_id=$TG_CHAT_ID" \
                -d "text=$mensaje" \
                -d "parse_mode=HTML" > /dev/null 2>&1
        fi
    fi
}

# ════════════════════════════════════════════════════════════
#   BANNER
# ════════════════════════════════════════════════════════════
mostrar_banner() {
    clear
    echo -e "${CYAN}"
    echo "   ██████╗████████╗███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗ "
    echo "  ██╔════╝╚══██╔══╝████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗"
    echo "  ██║        ██║   ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝"
    echo "  ██║        ██║   ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗"
    echo "  ╚██████╗   ██║   ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║"
    echo "   ╚═════╝   ╚═╝   ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝"
    echo -e "${YELLOW}"
    echo "                    Gestor Todo en Uno - by CHARLY_TRICKS"
    echo "                    Versión 1.0 | zonadnsbot.skin"
    echo -e "${CYAN}  ══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# ── Estado de servicios en banner ────────────────────────────
mostrar_estados() {
    local hysteria_v1=$( systemctl is-active hysteria-v1 2>/dev/null )
    local hysteria_v2=$( systemctl is-active hysteria-v2 2>/dev/null )
    local pymanager=$( systemctl is-active pymanager 2>/dev/null )
    local dropbear=$( systemctl is-active dropbear 2>/dev/null )
    local stunnel=$( systemctl is-active "$(stunnel_svc)" 2>/dev/null )
    local openvpn=$( systemctl is-active openvpn@server 2>/dev/null )
    local slowdns=$( systemctl is-active slowdns 2>/dev/null )
    local brook=$( systemctl is-active brook 2>/dev/null )
    local udpcustom=$( systemctl is-active udp-custom 2>/dev/null )
    local psiphon=$( pgrep -f "psiphond run" > /dev/null 2>&1 && echo "active" || echo "inactive" )

    estado() { [ "$1" = "active" ] && echo -e "${GREEN}●${NC}" || echo -e "${RED}●${NC}"; }

    echo -e "  $(estado $hysteria_v1) Hysteria V1   $(estado $hysteria_v2) Hysteria V2   $(estado $pymanager) WebSocket     $(estado $dropbear) Dropbear"
    echo -e "  $(estado $stunnel) Stunnel       $(estado $openvpn) OpenVPN       $(estado $slowdns) SlowDNS       $(estado $brook) Brook"
    echo -e "  $(estado $udpcustom) UDP-Custom    $(estado $psiphon) Psiphon"
    echo ""
}

# ════════════════════════════════════════════════════════════
#   HYSTERIA V1/V2
# ════════════════════════════════════════════════════════════
CONFIG_HY_DIR="/etc/hysteria"
DB_V1="$CONFIG_HY_DIR/charly_users_v1.db"
DB_V2="$CONFIG_HY_DIR/charly_users_v2.db"
CONFIG_V1="$CONFIG_HY_DIR/config_v1.json"
CONFIG_V2="$CONFIG_HY_DIR/config_v2.yaml"
BIN_V1="/usr/local/bin/hysteria-v1"
BIN_V2="/usr/local/bin/hysteria-v2"

init_db_hysteria() {
    local db="$1"
    mkdir -p "$CONFIG_HY_DIR"
    sqlite3 "$db" "CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
}

actualizar_config_hysteria() {
    local ver="$1"
    if [ "$ver" = "v1" ]; then
        local users=$(sqlite3 "$DB_V1" "SELECT username || ':' || password FROM users WHERE activo=1 AND (expires_at IS NULL OR expires_at > datetime('now'));" 2>/dev/null)
        local arr=$(echo "$users" | awk -F'\n' '{for(i=1;i<=NF;i++) if($i!="") printf "\"" $i "\"" (i==NF ? "" : ",")}')
        jq ".auth.config = [$arr]" "$CONFIG_V1" > "${CONFIG_V1}.tmp" 2>/dev/null && mv "${CONFIG_V1}.tmp" "$CONFIG_V1"
        systemctl restart hysteria-v1 2>/dev/null
    else
        systemctl restart hysteria-v2 2>/dev/null
    fi
}

instalar_hysteria_v1() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Hysteria V1...${NC}"
    instalar_deps_base
    mkdir -p "$CONFIG_HY_DIR"
    echo -e "${YELLOW}  [*] Descargando Hysteria V1...${NC}"
    wget -q --show-progress -O "$BIN_V1" \
        "https://github.com/HyNetwork/hysteria/releases/download/v1.3.5/hysteria-linux-amd64"
    chmod +x "$BIN_V1"
    openssl ecparam -genkey -name prime256v1 -out "$CONFIG_HY_DIR/v1.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$CONFIG_HY_DIR/v1.key" \
        -out "$CONFIG_HY_DIR/v1.crt" -subj "/CN=bing.com" 2>/dev/null
    echo -e "${YELLOW}"
    read -p "  Puerto UDP: " puerto
    read -p "  Obfuscación: " obfs
    read -p "  Velocidad subida (Mbps): " up
    read -p "  Velocidad bajada (Mbps): " down
    echo -e "${NC}"
    init_db_hysteria "$DB_V1"
    cat > "$CONFIG_V1" <<EOF
{
    "listen": ":$puerto",
    "protocol": "udp",
    "cert": "$CONFIG_HY_DIR/v1.crt",
    "key": "$CONFIG_HY_DIR/v1.key",
    "up": "$up Mbps",
    "up_mbps": $up,
    "down": "$down Mbps",
    "down_mbps": $down,
    "disable_udp": false,
    "obfs": "$obfs",
    "auth": { "mode": "passwords", "config": [] }
}
EOF
    cat > /etc/systemd/system/hysteria-v1.service <<EOF
[Unit]
Description=Hysteria V1 - CTManager
After=network.target
[Service]
User=root
ExecStart=$BIN_V1 server --config $CONFIG_V1 --log-level 0
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-v1 > /dev/null 2>&1
    systemctl start hysteria-v1
    iptables -I INPUT -p udp --dport "$puerto" -j ACCEPT 2>/dev/null
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    echo -e "${GREEN}  [✓] Hysteria V1 instalado en puerto $puerto${NC}"
    log "Hysteria V1 instalado puerto $puerto"
    send_telegram "✅ <b>Hysteria V1 instalado</b>%0APuerto: $puerto"
    sleep 2
}

instalar_hysteria_v2() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Hysteria V2...${NC}"
    instalar_deps_base
    mkdir -p "$CONFIG_HY_DIR"
    echo -e "${YELLOW}  [*] Descargando Hysteria V2...${NC}"
    LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name' 2>/dev/null)
    wget -q --show-progress -O "$BIN_V2" \
        "https://github.com/apernet/hysteria/releases/download/$LATEST/hysteria-linux-amd64"
    chmod +x "$BIN_V2"
    openssl ecparam -genkey -name prime256v1 -out "$CONFIG_HY_DIR/v2.key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$CONFIG_HY_DIR/v2.key" \
        -out "$CONFIG_HY_DIR/v2.crt" -subj "/CN=bing.com" 2>/dev/null
    echo -e "${YELLOW}"
    read -p "  Puerto UDP: " puerto
    read -p "  Contraseña obfs: " obfs
    read -p "  Velocidad subida (Mbps): " up
    read -p "  Velocidad bajada (Mbps): " down
    echo -e "${NC}"
    init_db_hysteria "$DB_V2"
    cat > "$CONFIG_V2" <<EOF
listen: :$puerto
tls:
  cert: $CONFIG_HY_DIR/v2.crt
  key: $CONFIG_HY_DIR/v2.key
obfs:
  type: salamander
  salamander:
    password: $obfs
bandwidth:
  up: ${up} mbps
  down: ${down} mbps
auth:
  type: userpass
  userpass: {}
EOF
    cat > /etc/systemd/system/hysteria-v2.service <<EOF
[Unit]
Description=Hysteria V2 - CTManager
After=network.target
[Service]
User=root
ExecStart=$BIN_V2 server --config $CONFIG_V2
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-v2 > /dev/null 2>&1
    systemctl start hysteria-v2
    iptables -I INPUT -p udp --dport "$puerto" -j ACCEPT 2>/dev/null
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    echo -e "${GREEN}  [✓] Hysteria V2 instalado en puerto $puerto${NC}"
    log "Hysteria V2 instalado puerto $puerto"
    send_telegram "✅ <b>Hysteria V2 instalado</b>%0APuerto: $puerto"
    sleep 2
}

menu_hysteria_usuarios() {
    while true; do
        mostrar_banner
        echo -e "  ${CYAN}── GESTIÓN DE USUARIOS HYSTERIA ────────────${NC}"
        echo -e "  ${YELLOW}1)${NC}  Agregar usuario"
        echo -e "  ${YELLOW}2)${NC}  Editar usuario"
        echo -e "  ${YELLOW}3)${NC}  Eliminar usuario"
        echo -e "  ${YELLOW}4)${NC}  Ver usuarios"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) agregar_usuario_hysteria ;;
            2) editar_usuario_hysteria ;;
            3) eliminar_usuario_hysteria ;;
            4) ver_usuarios_hysteria ;;
            0) break ;;
        esac
    done
}

seleccionar_version_hysteria() {
    echo -e "${YELLOW}  ¿Versión?${NC}"
    echo "  1) Hysteria V1"
    echo "  2) Hysteria V2"
    read -p "  Opción: " ver
    [ "$ver" = "1" ] && echo "v1" || echo "v2"
}

agregar_usuario_hysteria() {
    mostrar_banner
    echo -e "  ${CYAN}── AGREGAR USUARIO HYSTERIA ──${NC}"
    local ver=$(seleccionar_version_hysteria)
    local db=$( [ "$ver" = "v1" ] && echo "$DB_V1" || echo "$DB_V2" )
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Contraseña: " password
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
        expires_show=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null)
    else
        expires="NULL"; expires_show="Sin límite"
    fi
    sqlite3 "$db" "INSERT INTO users (username, password, expires_at) VALUES ('$username', '$password', $expires);" 2>/dev/null
    if [ $? -eq 0 ]; then
        actualizar_config_hysteria "$ver"
        echo -e "${GREEN}  [✓] Usuario '$username' agregado. Expira: $expires_show${NC}"
        send_telegram "👤 <b>Usuario Hysteria $ver</b>%0AUsuario: $username%0AExpira: $expires_show"
    else
        echo -e "${RED}  [✗] Error: El usuario ya existe.${NC}"
    fi
    sleep 2
}

editar_usuario_hysteria() {
    mostrar_banner
    echo -e "  ${CYAN}── EDITAR USUARIO HYSTERIA ──${NC}"
    local ver=$(seleccionar_version_hysteria)
    local db=$( [ "$ver" = "v1" ] && echo "$DB_V1" || echo "$DB_V2" )
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Nueva contraseña: " password
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
    else
        expires="NULL"
    fi
    sqlite3 "$db" "UPDATE users SET password='$password', expires_at=$expires WHERE username='$username';" 2>/dev/null
    actualizar_config_hysteria "$ver"
    echo -e "${GREEN}  [✓] Usuario '$username' actualizado.${NC}"
    sleep 2
}

eliminar_usuario_hysteria() {
    mostrar_banner
    echo -e "  ${CYAN}── ELIMINAR USUARIO HYSTERIA ──${NC}"
    local ver=$(seleccionar_version_hysteria)
    local db=$( [ "$ver" = "v1" ] && echo "$DB_V1" || echo "$DB_V2" )
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    echo -e "${NC}"
    sqlite3 "$db" "DELETE FROM users WHERE username='$username';" 2>/dev/null
    actualizar_config_hysteria "$ver"
    echo -e "${GREEN}  [✓] Usuario '$username' eliminado.${NC}"
    send_telegram "🗑️ <b>Usuario Hysteria eliminado</b>%0AUsuario: $username"
    sleep 2
}

ver_usuarios_hysteria() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS HYSTERIA ──${NC}"
    local ver=$(seleccionar_version_hysteria)
    local db=$( [ "$ver" = "v1" ] && echo "$DB_V1" || echo "$DB_V2" )
    echo -e "${YELLOW}"
    printf "  %-20s %-20s %-12s %-20s\n" "USUARIO" "CONTRASEÑA" "ESTADO" "EXPIRA"
    echo "  ──────────────────────────────────────────────────────────────"
    while IFS='|' read -r user pass activo expires; do
        estado=$( [ "$activo" = "1" ] && echo "${GREEN}Activo${NC}" || echo "${RED}Inactivo${NC}" )
        expires="${expires:-Sin límite}"
        printf "  ${CYAN}%-20s${NC} %-20s %b     %-20s\n" "$user" "$pass" "$estado" "$expires"
    done < <(sqlite3 "$db" "SELECT username, password, activo, COALESCE(expires_at,'Sin límite') FROM users;" 2>/dev/null)
    echo -e "${NC}"
    read -p "  Presioná Enter para continuar..."
}

menu_hysteria() {
    while true; do
        mostrar_banner
        local v1=$( systemctl is-active hysteria-v1 2>/dev/null )
        local v2=$( systemctl is-active hysteria-v2 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── HYSTERIA ─────────────────────────────────${NC}"
        echo -e "  Hysteria V1: $(estado $v1)   Hysteria V2: $(estado $v2)"
        echo ""
        echo -e "  ${CYAN}── INSTALACIÓN ──────────────────────────────${NC}"
        echo -e "  ${YELLOW}1)${NC}  Instalar Hysteria V1"
        echo -e "  ${YELLOW}2)${NC}  Instalar Hysteria V2"
        echo -e "  ${YELLOW}3)${NC}  Instalar ambas"
        echo ""
        echo -e "  ${CYAN}── USUARIOS ─────────────────────────────────${NC}"
        echo -e "  ${YELLOW}4)${NC}  Gestionar usuarios"
        echo ""
        echo -e "  ${CYAN}── SERVICIOS ────────────────────────────────${NC}"
        echo -e "  ${YELLOW}5)${NC}  Reiniciar V1"
        echo -e "  ${YELLOW}6)${NC}  Reiniciar V2"
        echo -e "  ${YELLOW}7)${NC}  Ver logs V1"
        echo -e "  ${YELLOW}8)${NC}  Ver logs V2"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_hysteria_v1 ;;
            2) instalar_hysteria_v2 ;;
            3) instalar_hysteria_v1; instalar_hysteria_v2 ;;
            4) menu_hysteria_usuarios ;;
            5) systemctl restart hysteria-v1 && echo -e "${GREEN}  [✓] V1 reiniciado.${NC}"; sleep 1 ;;
            6) systemctl restart hysteria-v2 && echo -e "${GREEN}  [✓] V2 reiniciado.${NC}"; sleep 1 ;;
            7) journalctl -u hysteria-v1 -n 50 --no-pager; read -p "Enter..." ;;
            8) journalctl -u hysteria-v2 -n 50 --no-pager; read -p "Enter..." ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   WEBSOCKET / SOCKS PYTHON
# ════════════════════════════════════════════════════════════
WS_CONFIG_DIR="/etc/ctmanager/websocket"
SOCKS_DB="/etc/ctmanager/socks/users.db"
WS_DB="$WS_CONFIG_DIR/users.db"
WS_CONFIG="$WS_CONFIG_DIR/config.json"
WS_SERVER="/etc/ctmanager/websocket/proxy.py"
SOCKS_DIR="/etc/ctmanager/socks"

init_db_ws() {
    mkdir -p "$WS_CONFIG_DIR"
    sqlite3 "$WS_DB" "CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        max_connections INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        last_seen TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
}

instalar_websocket() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando WebSocket Proxy...${NC}"
    instalar_deps_base
    pip3 install websockets 2>/dev/null
    mkdir -p "$WS_CONFIG_DIR"
    init_db_ws

    echo -e "${YELLOW}"
    read -p "  Puerto WS (ej: 80): " ws_port
    read -p "  Puerto WSS (ej: 443): " wss_port
    echo ""
    echo -e "  Puerto destino:"
    echo "  1) SSH (22)  2) Dropbear 443  3) Dropbear 80  4) Manual"
    read -p "  Opción: " dest_opt
    case $dest_opt in
        1) target_port=22; target_host="127.0.0.1" ;;
        2) target_port=443; target_host="127.0.0.1" ;;
        3) target_port=80; target_host="127.0.0.1" ;;
        *) read -p "  Host destino: " target_host
           read -p "  Puerto destino: " target_port ;;
    esac
    echo ""
    echo "  Payload: 1) HTTP 200 OK  2) HTTP 101 Switching Protocols"
    read -p "  Opción [1]: " payload_opt
    [ "$payload_opt" = "2" ] && payload="101" || payload="200"
    read -p "  Máx conexiones por usuario [3]: " max_conn
    [ -z "$max_conn" ] && max_conn=3
    echo -e "${NC}"

    cat > "$WS_CONFIG" <<EOF
{
    "ws_port": $ws_port,
    "wss_port": $wss_port,
    "target_host": "$target_host",
    "target_port": $target_port,
    "payload": "$payload",
    "enable_ws": true,
    "enable_wss": true,
    "max_connections_per_user": $max_conn
}
EOF

    # Crear servidor WebSocket/HTTP Python
    cat > "$WS_SERVER" << 'PYEOF'
#!/usr/bin/env python3
import socket, threading, sys, sqlite3, base64, os
from datetime import datetime

CONFIG_FILE = "/etc/ctmanager/websocket/config.json"
DB_FILE     = "/etc/ctmanager/websocket/users.db"

def load_config():
    import json
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except:
        return {"target_host": "127.0.0.1", "target_port": 22, "payload": "200", "max_connections_per_user": 3}

def authenticate(username, password):
    try:
        conn = sqlite3.connect(DB_FILE)
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM users")
        total = cur.fetchone()[0]
        if total == 0:
            conn.close()
            return True  # Sin usuarios = acceso libre
        cur.execute("""SELECT * FROM users 
            WHERE username=? AND password=? AND activo=1
            AND (expires_at IS NULL OR expires_at > datetime('now'))""", 
            (username, password))
        result = cur.fetchone()
        conn.close()
        return result is not None
    except:
        return True

def parse_auth(data):
    try:
        text = data.decode('utf-8', errors='ignore')
        for line in text.split('\r\n'):
            # Header Authorization/Proxy-Authorization
            if line.lower().startswith('proxy-authorization:') or line.lower().startswith('authorization:'):
                parts = line.split(' ', 2)
                if len(parts) >= 2:
                    try:
                        decoded = base64.b64decode(parts[-1]).decode('utf-8', errors='ignore')
                        if ':' in decoded:
                            return decoded.split(':', 1)
                    except: pass
                    # Sin base64: Basic usuario:contraseña
                    raw = parts[-1]
                    if ':' in raw:
                        return raw.split(':', 1)

            # Formato host:puerto@usuario:contraseña en cualquier línea
            if '@' in line:
                try:
                    at_parts = line.split('@')
                    for part in at_parts[1:]:
                        # part puede ser "usuario:contraseña" o "usuario:contraseña HTTP/1.1"
                        creds = part.strip().split(' ')[0]
                        if ':' in creds:
                            u, p = creds.split(':', 1)
                            if u and p:
                                return u, p
                except: pass

            # Path: GET /usuario/contraseña HTTP
            if line.startswith('GET ') or line.startswith('CONNECT ') or line.startswith('POST ') or line.startswith('GET-'):
                parts = line.split(' ')
                if len(parts) >= 2:
                    path = parts[1].strip('/').split('/')
                    if len(path) >= 2 and path[0] and path[1]:
                        return path[0], path[1]

    except: pass
    return None, None

def forward(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data: break
            dst.sendall(data)
    except: pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle_client(client_socket, cfg):
    payloads = {
        "200": "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "101": "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    }
    payload = payloads.get(str(cfg.get("payload", "200")), payloads["200"])
    target_host = cfg.get("target_host", "127.0.0.1")
    target_port = int(cfg.get("target_port", 22))

    try:
        data = client_socket.recv(4096)
        if not data:
            client_socket.close()
            return

        # Verificar autenticación
        username, password = parse_auth(data)
        if not authenticate(username or "", password or ""):
            client_socket.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
            client_socket.close()
            return

        # Enviar payload
        client_socket.sendall(payload.encode())

        # Conectar al destino
        dest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dest.connect((target_host, target_port))

        # Puente bidireccional
        threading.Thread(target=forward, args=(client_socket, dest), daemon=True).start()
        threading.Thread(target=forward, args=(dest, client_socket), daemon=True).start()

    except Exception as e:
        try: client_socket.close()
        except: pass

def start_server(port, cfg):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', port))
    srv.listen(100)
    print(f"[WS] Puerto {port} -> {cfg.get('target_host')}:{cfg.get('target_port')} payload:{cfg.get('payload','200')}")
    while True:
        client, addr = srv.accept()
        threading.Thread(target=handle_client, args=(client, cfg), daemon=True).start()

if __name__ == "__main__":
    cfg = load_config()
    ports = []
    if cfg.get("enable_ws") and cfg.get("ws_port"):
        ports.append(int(cfg["ws_port"]))
    if cfg.get("enable_wss") and cfg.get("wss_port"):
        ports.append(int(cfg["wss_port"]))
    if not ports:
        ports = [8080]
    threads = []
    for p in ports:
        t = threading.Thread(target=start_server, args=(p, cfg), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
PYEOF
    chmod +x "$WS_SERVER"

    cat > /etc/systemd/system/ctmanager-ws.service <<EOF
[Unit]
Description=CTManager WebSocket Proxy
After=network.target
[Service]
User=root
ExecStart=/usr/bin/python3 $WS_SERVER
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ctmanager-ws > /dev/null 2>&1
    systemctl start ctmanager-ws
    iptables -I INPUT -p tcp --dport "$ws_port" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport "$wss_port" -j ACCEPT 2>/dev/null
    echo -e "${GREEN}  [✓] WebSocket instalado. WS:$ws_port / WSS:$wss_port${NC}"
    send_telegram "✅ <b>WebSocket instalado</b>%0AWS: $ws_port | WSS: $wss_port"
    sleep 2
}

instalar_socks() {
    mostrar_banner
    echo -e "${CYAN}  [*] Configurando SOCKS Python (Injector)...${NC}"
    mkdir -p "$SOCKS_DIR"

    echo -e "${YELLOW}"
    read -p "  Puerto de escucha (ej: 8080): " listen_port
    echo -e "  Puerto de destino:"
    echo "  1) SSH (22)  2) Dropbear 443  3) Dropbear 80  4) Manual"
    read -p "  Opción: " dest_opt
    case $dest_opt in
        1) dest_port=22 ;;
        2) dest_port=443 ;;
        3) dest_port=80 ;;
        *) read -p "  Puerto destino: " dest_port ;;
    esac
    echo "  Payload: 1) HTTP 200  2) HTTP 101"
    read -p "  Opción: " payload_opt
    [ "$payload_opt" = "2" ] && payload="101" || payload="200"
    echo -e "${NC}"

    # Crear motor proxy.py
    cat > "$SOCKS_DIR/proxy.py" << 'PYEOF'
#!/usr/bin/env python3
import socket, threading, sys, sqlite3
from datetime import datetime

DB_FILE = "/etc/ctmanager/socks/users.db"

def authenticate(username, password):
    try:
        conn = sqlite3.connect(DB_FILE)
        cur = conn.cursor()
        cur.execute("""
            SELECT * FROM users 
            WHERE username=? AND password=? AND activo=1
            AND (expires_at IS NULL OR expires_at > datetime('now'))
        """, (username, password))
        result = cur.fetchone()
        conn.close()
        return result is not None
    except:
        return True  # Si no hay BD, permitir conexión

def init_db():
    try:
        conn = sqlite3.connect(DB_FILE)
        conn.execute("""CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL,
            created_at TEXT DEFAULT (datetime('now')),
            expires_at TEXT,
            activo INTEGER DEFAULT 1
        )""")
        conn.commit()
        conn.close()
    except: pass

def parse_auth(data):
    """Extrae usuario:contraseña del header HTTP"""
    try:
        text = data.decode('utf-8', errors='ignore')
        for line in text.split('\r\n'):
            if line.lower().startswith('proxy-authorization:') or line.lower().startswith('authorization:'):
                parts = line.split(' ', 2)
                if len(parts) >= 2:
                    import base64
                    decoded = base64.b64decode(parts[-1]).decode('utf-8', errors='ignore')
                    if ':' in decoded:
                        return decoded.split(':', 1)
        # Buscar en path: GET /usuario/contraseña HTTP
        for line in text.split('\r\n'):
            if line.startswith('GET ') or line.startswith('CONNECT ') or line.startswith('POST '):
                parts = line.split(' ')
                if len(parts) >= 2:
                    path = parts[1].strip('/').split('/')
                    if len(path) >= 2:
                        return path[0], path[1]
    except: pass
    return None, None

def handle_client(client_socket, listen_port, dest_host, dest_port, payload_code):
    payloads = {
        "200": "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "101": "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    }
    response = payloads.get(payload_code, payloads["200"])
    try:
        data = client_socket.recv(4096)
        if not data:
            client_socket.close()
            return

        # Verificar si hay usuarios en la BD
        try:
            conn = sqlite3.connect(DB_FILE)
            cur = conn.cursor()
            cur.execute("SELECT COUNT(*) FROM users")
            total = cur.fetchone()[0]
            conn.close()
        except:
            total = 0

        # Solo autenticar si hay usuarios registrados
        if total > 0:
            username, password = parse_auth(data)
            if not username or not authenticate(username, password):
                client_socket.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
                client_socket.close()
                print(f"[SOCKS {listen_port}] Auth fallida - usuario: {username}")
                return
            print(f"[SOCKS {listen_port}] {username} conectado -> {dest_host}:{dest_port}")
        
        client_socket.sendall(response.encode())
        dest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dest.connect((dest_host, dest_port))
        threading.Thread(target=forward, args=(client_socket, dest), daemon=True).start()
        threading.Thread(target=forward, args=(dest, client_socket), daemon=True).start()
    except Exception as e:
        client_socket.close()

def forward(src, dst):
    try:
        while True:
            data = src.recv(4096)
            if not data: break
            dst.sendall(data)
    except: pass
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def start(listen_port, dest_host, dest_port, payload_code):
    init_db()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', listen_port))
    srv.listen(100)
    print(f"[SOCKS] Puerto {listen_port} -> {dest_host}:{dest_port}")
    while True:
        client, addr = srv.accept()
        threading.Thread(target=handle_client, args=(client, listen_port, dest_host, dest_port, payload_code), daemon=True).start()

if __name__ == "__main__":
    start(int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4])
PYEOF

    local svc="socks-$listen_port.service"
    local logfile="$SOCKS_DIR/socks-$listen_port.log"
    touch "$logfile"
    cat > "/etc/systemd/system/$svc" <<EOF
[Unit]
Description=CTManager SOCKS Injector port $listen_port
After=network.target
[Service]
ExecStart=/usr/bin/python3 $SOCKS_DIR/proxy.py $listen_port 127.0.0.1 $dest_port $payload
StandardOutput=file:$logfile
StandardError=file:$logfile
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$svc" > /dev/null 2>&1
    systemctl start "$svc"
    iptables -I INPUT -p tcp --dport "$listen_port" -j ACCEPT 2>/dev/null
    echo -e "${GREEN}  [✓] SOCKS Injector instalado en puerto $listen_port -> $dest_port${NC}"
    sleep 2
}

menu_websocket_socks() {
    while true; do
        mostrar_banner
        local ws=$( systemctl is-active ctmanager-ws 2>/dev/null )
        estado_ws() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── WEBSOCKET & SOCKS PYTHON ────────────────${NC}"
        echo -e "  WebSocket: $(estado_ws $ws)"
        echo ""
        echo -e "  ${CYAN}── WEBSOCKET ─────────────────────────────${NC}"
        echo -e "  ${YELLOW}1)${NC}  Instalar WebSocket Proxy (WS/WSS)"
        echo -e "  ${YELLOW}2)${NC}  Agregar usuario WebSocket"
        echo -e "  ${YELLOW}3)${NC}  Ver usuarios WebSocket"
        echo -e "  ${YELLOW}4)${NC}  Reiniciar WebSocket"
        echo -e "  ${YELLOW}5)${NC}  Ver logs WebSocket"
        echo ""
        echo -e "  ${CYAN}── SOCKS PYTHON ──────────────────────────${NC}"
        echo -e "  ${YELLOW}6)${NC}  Instalar SOCKS Injector"
        echo -e "  ${YELLOW}7)${NC}  Agregar usuario SOCKS"
        echo -e "  ${YELLOW}8)${NC}  Editar usuario SOCKS"
        echo -e "  ${YELLOW}9)${NC}  Eliminar usuario SOCKS"
        echo -e "  ${YELLOW}10)${NC} Ver usuarios SOCKS"
        echo -e "  ${YELLOW}11)${NC} Ver servicios SOCKS"
        echo -e "  ${YELLOW}12)${NC} Detener todos los SOCKS"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_websocket ;;
            2) agregar_usuario_ws ;;
            3) ver_usuarios_ws ;;
            4) systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            5) journalctl -u ctmanager-ws -n 50 --no-pager; read -p "Enter..." ;;
            6) instalar_socks ;;
            7) agregar_usuario_socks ;;
            8) editar_usuario_socks ;;
            9) eliminar_usuario_socks ;;
            10) ver_usuarios_socks ;;
            11) listar_socks ;;
            12) detener_socks ;;
            0) break ;;
        esac
    done
}

agregar_usuario_ws() {
    mostrar_banner
    init_db_ws
    echo -e "  ${CYAN}── AGREGAR USUARIO WEBSOCKET ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Contraseña: " password
    read -p "  Máx conexiones: " max_conn
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
        expires_show=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null)
    else
        expires="NULL"; expires_show="Sin límite"
    fi
    sqlite3 "$WS_DB" "INSERT INTO users (username, password, max_connections, expires_at) VALUES ('$username', '$password', $max_conn, $expires);" 2>/dev/null
    [ $? -eq 0 ] && echo -e "${GREEN}  [✓] Usuario '$username' agregado. Expira: $expires_show${NC}" || echo -e "${RED}  [✗] Error: usuario ya existe.${NC}"
    sleep 2
}

ver_usuarios_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS WEBSOCKET ──${NC}"
    printf "  %-18s %-18s %-6s %-20s\n" "USUARIO" "CONTRASEÑA" "CONN" "EXPIRA"
    echo "  ────────────────────────────────────────────────────────"
    while IFS='|' read -r user pass max expires activo; do
        estado=$( [ "$activo" = "1" ] && echo -e "${GREEN}●${NC}" || echo -e "${RED}●${NC}" )
        printf "  %b %-17s %-18s %-6s %-20s\n" "$estado" "$user" "$pass" "$max" "${expires:-Sin límite}"
    done < <(sqlite3 "$WS_DB" "SELECT username, password, max_connections, COALESCE(expires_at,'Sin límite'), activo FROM users;" 2>/dev/null)
    echo ""
    read -p "  Presioná Enter para continuar..."
}

listar_socks() {
    mostrar_banner
    echo -e "  ${CYAN}── SERVICIOS SOCKS ACTIVOS ──${NC}"
    printf "  %-30s %-10s\n" "SERVICIO" "ESTADO"
    echo "  ──────────────────────────────────────────"
    for s in /etc/systemd/system/socks-*.service; do
        [ -f "$s" ] || continue
        local sname=$(basename "$s")
        if systemctl is-active --quiet "$sname"; then
            printf "  %-30s %b\n" "$sname" "${GREEN}[ON]${NC}"
        else
            printf "  %-30s %b\n" "$sname" "${RED}[OFF]${NC}"
        fi
    done
    echo ""
    read -p "  Presioná Enter para continuar..."
}

detener_socks() {
    read -p "  ¿Detener TODOS los SOCKS? (s/n): " confirm
    [ "$confirm" != "s" ] && return
    for s in /etc/systemd/system/socks-*.service; do
        [ -f "$s" ] || continue
        local sname=$(basename "$s")
        systemctl stop "$sname"
        systemctl disable "$sname" > /dev/null 2>&1
        rm -f "$s"
    done
    systemctl daemon-reload
    echo -e "${GREEN}  [✓] Todos los SOCKS detenidos.${NC}"
    sleep 2
}

init_db_socks() {
    mkdir -p /etc/ctmanager/socks
    sqlite3 "$SOCKS_DB" "CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
}

agregar_usuario_socks() {
    mostrar_banner
    init_db_socks
    echo -e "  ${CYAN}── AGREGAR USUARIO SOCKS ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Contraseña: " password
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
        expires_show=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null)
    else
        expires="NULL"; expires_show="Sin límite"
    fi
    sqlite3 "$SOCKS_DB" "INSERT INTO users (username, password, expires_at) VALUES ('$username', '$password', $expires);" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}  [✓] Usuario SOCKS '$username' agregado. Expira: $expires_show${NC}"
        # Reinicar todos los servicios SOCKS para aplicar cambios
        for s in /etc/systemd/system/socks-*.service; do
            [ -f "$s" ] && systemctl restart "$(basename $s)" 2>/dev/null
        done
    else
        echo -e "${RED}  [✗] Error: usuario ya existe.${NC}"
    fi
    sleep 2
}

editar_usuario_socks() {
    mostrar_banner
    echo -e "  ${CYAN}── EDITAR USUARIO SOCKS ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Nueva contraseña: " password
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
    else
        expires="NULL"
    fi
    sqlite3 "$SOCKS_DB" "UPDATE users SET password='$password', expires_at=$expires WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Usuario '$username' actualizado.${NC}"
    sleep 2
}

eliminar_usuario_socks() {
    mostrar_banner
    echo -e "  ${CYAN}── ELIMINAR USUARIO SOCKS ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    echo -e "${NC}"
    sqlite3 "$SOCKS_DB" "DELETE FROM users WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Usuario '$username' eliminado.${NC}"
    sleep 2
}

ver_usuarios_socks() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS SOCKS ──${NC}"
    printf "  %-20s %-20s %-12s %-20s
" "USUARIO" "CONTRASEÑA" "ESTADO" "EXPIRA"
    echo "  ──────────────────────────────────────────────────────────────"
    while IFS='|' read -r user pass activo expires; do
        estado=$( [ "$activo" = "1" ] && echo -e "${GREEN}Activo${NC}" || echo -e "${RED}Inactivo${NC}" )
        printf "  ${CYAN}%-20s${NC} %-20s %b     %-20s
" "$user" "$pass" "$estado" "${expires:-Sin límite}"
    done < <(sqlite3 "$SOCKS_DB" "SELECT username, password, activo, COALESCE(expires_at,'Sin límite') FROM users;" 2>/dev/null)
    echo ""
    read -p "  Presioná Enter para continuar..."
}

# ════════════════════════════════════════════════════════════
#   BADVPN / UDP-CUSTOM
# ════════════════════════════════════════════════════════════
instalar_badvpn() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando BadVPN / UDP-Custom...${NC}"
    instalar_deps_base
    pkg_install cmake git "$(pkg_name build)"

    echo -e "${YELLOW}"
    read -p "  Puerto UDP [default 36712]: " listen_port
    [ -z "$listen_port" ] && listen_port="36712"
    read -p "  Rango IPTables [default 1:65535]: " iptables_range
    [ -z "$iptables_range" ] && iptables_range="1:65535"
    echo -e "${NC}"

    echo -e "${YELLOW}  [*] Compilando BadVPN...${NC}"
    rm -rf /tmp/badvpn-build
    mkdir /tmp/badvpn-build && cd /tmp/badvpn-build
    git clone https://github.com/ambrop72/badvpn.git . > /dev/null 2>&1
    mkdir build && cd build
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 > /dev/null 2>&1
    make > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        mv udpgw/badvpn-udpgw /usr/local/bin/udp-custom
        chmod +x /usr/local/bin/udp-custom
    else
        echo -e "${RED}  [✗] Error compilando BadVPN.${NC}"; sleep 2; return
    fi
    cd / && rm -rf /tmp/badvpn-build

    cat > /etc/systemd/system/udp-custom.service <<EOF
[Unit]
Description=CTManager UDP-Custom (BadVPN)
After=network.target
[Service]
ExecStart=/usr/local/bin/udp-custom --listen-addr 0.0.0.0:$listen_port
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable udp-custom > /dev/null 2>&1
    systemctl start udp-custom
    iptables -I INPUT -p udp --dport "$listen_port" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --match multiport --dports "$iptables_range" -j ACCEPT 2>/dev/null
    echo -e "${GREEN}  [✓] BadVPN/UDP-Custom instalado en puerto $listen_port${NC}"
    send_telegram "✅ <b>BadVPN instalado</b>%0APuerto: $listen_port"
    sleep 2
}

menu_badvpn() {
    while true; do
        mostrar_banner
        local udp=$( systemctl is-active udp-custom 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── BADVPN / UDP-CUSTOM ─────────────────────${NC}"
        echo -e "  UDP-Custom: $(estado $udp)"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar BadVPN/UDP-Custom"
        echo -e "  ${YELLOW}2)${NC}  Reiniciar servicio"
        echo -e "  ${YELLOW}3)${NC}  Detener servicio"
        echo -e "  ${YELLOW}4)${NC}  Ver estado"
        echo -e "  ${YELLOW}5)${NC}  Ver logs"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_badvpn ;;
            2) systemctl restart udp-custom && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            3) systemctl stop udp-custom && echo -e "${YELLOW}  [!] Detenido.${NC}"; sleep 1 ;;
            4) systemctl status udp-custom --no-pager; read -p "Enter..." ;;
            5) journalctl -u udp-custom -n 50 --no-pager; read -p "Enter..." ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   SLOWDNS / DNSTT
# ════════════════════════════════════════════════════════════
SLOWDNS_CONFIG="/etc/ctmanager/config/slowdns.conf"
SLOWDNS_KEY_DIR="/etc/ctmanager/config/slowdns"

instalar_slowdns() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando SlowDNS/DNSTT...${NC}"
    instalar_deps_base
    pkg_install git "$(pkg_name golang)"

    echo -e "${YELLOW}"
    read -p "  Dominio NS (ej: tuns.midominio.com): " ns_domain
    echo "  Puerto destino: 1) SSH(22)  2) Dropbear(443)  3) Manual"
    read -p "  Opción: " dest_opt
    case $dest_opt in
        1) dest_port=22 ;;
        2) dest_port=443 ;;
        *) read -p "  Puerto destino: " dest_port ;;
    esac
    echo -e "${NC}"

    echo -e "${YELLOW}  [*] Compilando DNSTT...${NC}"
    rm -rf /tmp/dnstt
    git clone https://github.com/v2fly/dnstt.git /tmp/dnstt > /dev/null 2>&1
    cd /tmp/dnstt/dnstt-server
    go build > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        mv dnstt-server /usr/local/bin/dnstt-server
        chmod +x /usr/local/bin/dnstt-server
    else
        echo -e "${RED}  [✗] Error compilando DNSTT.${NC}"; sleep 2; return
    fi
    cd / && rm -rf /tmp/dnstt

    mkdir -p "$SLOWDNS_KEY_DIR"
    /usr/local/bin/dnstt-server -gen-key \
        -privkey-file "$SLOWDNS_KEY_DIR/server.key" \
        -pubkey-file "$SLOWDNS_KEY_DIR/server.pub" 2>/dev/null

    local pubkey=$(cat "$SLOWDNS_KEY_DIR/server.pub")
    mkdir -p "$(dirname $SLOWDNS_CONFIG)"
    cat > "$SLOWDNS_CONFIG" <<EOF
NS_DOMAIN="$ns_domain"
DEST_PORT="$dest_port"
DNSTT_PORT="5300"
PUBLIC_KEY="$pubkey"
EOF

    cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=CTManager SlowDNS
After=network.target
[Service]
ExecStart=/usr/local/bin/dnstt-server -udp :5300 -privkey-file $SLOWDNS_KEY_DIR/server.key $ns_domain 127.0.0.1:$dest_port
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable slowdns > /dev/null 2>&1
    systemctl start slowdns
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
    iptables-save > /etc/iptables/rules.v4 2>/dev/null

    echo -e "${GREEN}  [✓] SlowDNS instalado${NC}"
    echo -e "${CYAN}  Clave pública: ${YELLOW}$pubkey${NC}"
    send_telegram "✅ <b>SlowDNS instalado</b>%0ANS: $ns_domain%0APub: $pubkey"
    sleep 3
}

menu_slowdns() {
    while true; do
        mostrar_banner
        local svc=$( systemctl is-active slowdns 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── SLOWDNS / DNSTT ─────────────────────────${NC}"
        echo -e "  SlowDNS: $(estado $svc)"
        if [ -f "$SLOWDNS_CONFIG" ]; then
            source "$SLOWDNS_CONFIG"
            echo -e "  NS: ${YELLOW}$NS_DOMAIN${NC}  Puerto destino: ${YELLOW}$DEST_PORT${NC}"
            echo -e "  Pub Key: ${YELLOW}${PUBLIC_KEY:0:30}...${NC}"
        fi
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar SlowDNS"
        echo -e "  ${YELLOW}2)${NC}  Ver claves"
        echo -e "  ${YELLOW}3)${NC}  Reiniciar servicio"
        echo -e "  ${YELLOW}4)${NC}  Iniciar/Parar servicio"
        echo -e "  ${YELLOW}5)${NC}  Ver logs"
        echo -e "  ${YELLOW}6)${NC}  Desinstalar"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_slowdns ;;
            2) [ -f "$SLOWDNS_KEY_DIR/server.pub" ] && echo -e "\n  ${GREEN}Pub Key:${NC} $(cat $SLOWDNS_KEY_DIR/server.pub)\n  ${RED}Priv Key:${NC} $(cat $SLOWDNS_KEY_DIR/server.key)"; read -p "  Enter..." ;;
            3) systemctl restart slowdns && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            4) systemctl is-active --quiet slowdns && systemctl stop slowdns && echo -e "${YELLOW}  [!] Detenido.${NC}" || systemctl start slowdns && echo -e "${GREEN}  [✓] Iniciado.${NC}"; sleep 1 ;;
            5) journalctl -u slowdns -n 50 --no-pager; read -p "  Enter..." ;;
            6) systemctl stop slowdns; systemctl disable slowdns; rm -f /etc/systemd/system/slowdns.service; rm -f /usr/local/bin/dnstt-server; rm -rf "$SLOWDNS_KEY_DIR"; echo -e "${GREEN}  [✓] Desinstalado.${NC}"; sleep 2 ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   DROPBEAR
# ════════════════════════════════════════════════════════════
instalar_dropbear() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Dropbear...${NC}"
    pkg_install dropbear net-tools

    echo -e "${YELLOW}"
    read -p "  Puertos separados por espacio (ej: 80 443 109): " port_input
    echo -e "${NC}"

    read -a ports <<< "$port_input"
    local dropbear_args=""
    local all_ok=true

    echo -e "${YELLOW}  Verificando puertos...${NC}"
    for port in "${ports[@]}"; do
        if netstat -tulpn 2>/dev/null | grep -q ":$port\b"; then
            echo -e "  Puerto $port.... ${RED}[OCUPADO]${NC}"
            all_ok=false
        else
            echo -e "  Puerto $port.... ${GREEN}[DISPONIBLE]${NC}"
            dropbear_args+=" -p $port"
        fi
    done

    if [ "$all_ok" = false ]; then
        echo -e "${RED}  [!] Hay puertos ocupados. Corregí e intentá de nuevo.${NC}"
        sleep 2; return
    fi

    sed -i 's/NO_START=1/NO_START=0/g' /etc/default/dropbear 2>/dev/null
    grep -q "DROPBEAR_EXTRA_ARGS" /etc/default/dropbear 2>/dev/null && \
        sed -i "s|^#*DROPBEAR_EXTRA_ARGS=.*|DROPBEAR_EXTRA_ARGS=\"$dropbear_args\"|g" /etc/default/dropbear || \
        echo "DROPBEAR_EXTRA_ARGS=\"$dropbear_args\"" >> /etc/default/dropbear

    mkdir -p /etc/dropbear
    cat > /etc/dropbear/banner << 'EOF'
╔══════════════════════════════════════════════╗
║                  CTMANAGER                   ║
║             by CHARLY_TRICKS                 ║
║           zonadnsbot.skin                    ║
╚══════════════════════════════════════════════╝
EOF
    grep -q "DROPBEAR_BANNER" /etc/default/dropbear 2>/dev/null || \
        echo 'DROPBEAR_BANNER="/etc/dropbear/banner"' >> /etc/default/dropbear

    systemctl daemon-reload
    systemctl enable dropbear > /dev/null 2>&1
    systemctl restart dropbear
    echo -e "${GREEN}  [✓] Dropbear instalado en puertos:$dropbear_args${NC}"
    send_telegram "✅ <b>Dropbear instalado</b>%0APuertos:$dropbear_args"
    sleep 2
}

menu_dropbear() {
    while true; do
        mostrar_banner
        local svc=$( systemctl is-active dropbear 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── DROPBEAR ────────────────────────────────${NC}"
        echo -e "  Dropbear: $(estado $svc)"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar / Modificar puertos"
        echo -e "  ${YELLOW}2)${NC}  Reiniciar servicio"
        echo -e "  ${YELLOW}3)${NC}  Ver estado"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_dropbear ;;
            2) systemctl restart dropbear && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            3) systemctl status dropbear --no-pager; read -p "  Enter..." ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   STUNNEL
# ════════════════════════════════════════════════════════════
instalar_stunnel() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Stunnel...${NC}"
    pkg_install "$(pkg_name stunnel)" openssl

    mkdir -p /etc/stunnel/certs /etc/stunnel/conf.d
    mkdir -p /var/log/stunnel4 /var/run/stunnel4

    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=AR/ST=BA/L=BA/O=CTManager/CN=ctmanager" \
        -keyout /etc/stunnel/certs/stunnel.key \
        -out /etc/stunnel/certs/stunnel.crt > /dev/null 2>&1
    cat /etc/stunnel/certs/stunnel.key /etc/stunnel/certs/stunnel.crt > /etc/stunnel/certs/stunnel.pem
    chmod 600 /etc/stunnel/certs/stunnel.pem

    cat > /etc/stunnel/stunnel.conf <<EOF
cert = /etc/stunnel/certs/stunnel.pem
setuid = stunnel4
setgid = stunnel4
pid = /var/run/stunnel4/stunnel.pid
output = /var/log/stunnel4/stunnel.log
debug = 3
options = NO_SSLv3
include = /etc/stunnel/conf.d/
EOF

    [ -f /etc/default/stunnel4 ] && sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
    STUNNEL_SVC=$(stunnel_svc)
    systemctl enable "$STUNNEL_SVC" > /dev/null 2>&1
    systemctl start "$STUNNEL_SVC"
    echo -e "${GREEN}  [✓] Stunnel instalado.${NC}"
    sleep 2
}

crear_tunel_stunnel() {
    mostrar_banner
    echo -e "  ${CYAN}── CREAR TÚNEL STUNNEL ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Puerto SSL (ej: 443): " listen_port
    echo "  Destino: 1) SSH(22)  2) Dropbear(80)  3) SOCKS(8080)  4) Manual"
    read -p "  Opción: " dest_opt
    case $dest_opt in
        1) dest_port=22 ;;
        2) dest_port=80 ;;
        3) dest_port=8080 ;;
        *) read -p "  Puerto destino: " dest_port ;;
    esac
    echo -e "${NC}"

    cat > "/etc/stunnel/conf.d/tunnel-$listen_port.conf" <<EOF
[stunnel-$listen_port]
accept = $listen_port
connect = 127.0.0.1:$dest_port
cert = /etc/stunnel/certs/stunnel.pem
EOF
    systemctl restart "$(stunnel_svc)"
    echo -e "${GREEN}  [✓] Túnel SSL $listen_port -> $dest_port creado.${NC}"
    sleep 2
}

menu_stunnel() {
    while true; do
        mostrar_banner
        local svc=$( systemctl is-active "$(stunnel_svc)" 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── STUNNEL SSL ─────────────────────────────${NC}"
        echo -e "  Stunnel: $(estado $svc)"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar Stunnel"
        echo -e "  ${YELLOW}2)${NC}  Crear túnel SSL"
        echo -e "  ${YELLOW}3)${NC}  Ver túneles activos"
        echo -e "  ${YELLOW}4)${NC}  Reiniciar Stunnel"
        echo -e "  ${YELLOW}5)${NC}  Ver estado"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_stunnel ;;
            2) crear_tunel_stunnel ;;
            3)
                echo -e "\n  ${CYAN}Túneles activos:${NC}"
                for f in /etc/stunnel/conf.d/*.conf; do
                    [ -f "$f" ] || continue
                    local listen=$(grep 'accept' "$f" | awk '{print $3}')
                    local dest=$(grep 'connect' "$f" | awk '{print $3}')
                    echo -e "  ${GREEN}●${NC} Puerto $listen -> $dest"
                done
                read -p "  Enter..."
                ;;
            4) systemctl restart "$(stunnel_svc)" && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            5) systemctl status "$(stunnel_svc)" --no-pager; read -p "  Enter..." ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   OPENVPN
# ════════════════════════════════════════════════════════════
instalar_openvpn() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando OpenVPN...${NC}"
    pkg_install openvpn "$(pkg_name easyrsa)" curl

    local ovpn_dir="/etc/openvpn"
    local easyrsa_dir="$ovpn_dir/easy-rsa"
    mkdir -p "$easyrsa_dir" "$ovpn_dir/clients"
    cp -r /usr/share/easy-rsa/* "$easyrsa_dir/" 2>/dev/null || \
    cp -r /usr/share/easy-rsa3/* "$easyrsa_dir/" 2>/dev/null || true

    cat > "$easyrsa_dir/vars" <<'EOF'
set_var EASYRSA_REQ_COUNTRY    "AR"
set_var EASYRSA_REQ_PROVINCE   "Buenos Aires"
set_var EASYRSA_REQ_CITY       "Buenos Aires"
set_var EASYRSA_REQ_ORG        "CTManager"
set_var EASYRSA_REQ_EMAIL      "admin@ctmanager.skin"
set_var EASYRSA_REQ_OU         "Community"
set_var EASYRSA_KEY_SIZE       2048
set_var EASYRSA_ALGO           rsa
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    365
EOF

    echo -e "${YELLOW}  [*] Generando PKI (puede tardar)...${NC}"
    cd "$easyrsa_dir"
    ./easyrsa init-pki > /dev/null 2>&1
    ./easyrsa build-ca nopass > /dev/null 2>&1
    ./easyrsa gen-dh > /dev/null 2>&1
    openvpn --genkey --secret pki/ta.key 2>/dev/null
    ./easyrsa build-server-full server nopass > /dev/null 2>&1

    cat > "$ovpn_dir/server.conf" <<'EOF'
port 1194
proto udp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth /etc/openvpn/easy-rsa/pki/ta.key 0
cipher AES-256-CBC
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
verb 3
EOF

    mkdir -p /var/log/openvpn
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
    systemctl enable openvpn@server > /dev/null 2>&1
    systemctl start openvpn@server
    echo -e "${GREEN}  [✓] OpenVPN instalado en puerto 1194/UDP${NC}"
    send_telegram "✅ <b>OpenVPN instalado</b>%0APuerto: 1194/UDP"
    sleep 2
}

crear_cliente_openvpn() {
    mostrar_banner
    echo -e "  ${CYAN}── CREAR CLIENTE OPENVPN ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Nombre del cliente: " client_name
    echo -e "${NC}"
    [ -z "$client_name" ] && return
    local easyrsa_dir="/etc/openvpn/easy-rsa"
    local clients_dir="/etc/openvpn/clients"
    cd "$easyrsa_dir"
    ./easyrsa build-client-full "$client_name" nopass > /dev/null 2>&1
    local server_ip=$(curl -s ipv4.icanhazip.com 2>/dev/null)
    cat > "$clients_dir/$client_name.ovpn" <<EOF
client
dev tun
proto udp
remote $server_ip 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
auth SHA256
verb 3
<ca>
$(cat "$easyrsa_dir/pki/ca.crt")
</ca>
<cert>
$(cat "$easyrsa_dir/pki/issued/$client_name.crt")
</cert>
<key>
$(cat "$easyrsa_dir/pki/private/$client_name.key")
</key>
<tls-auth>
$(cat "$easyrsa_dir/pki/ta.key")
</tls-auth>
EOF
    chmod 644 "$clients_dir/$client_name.ovpn"
    echo -e "${GREEN}  [✓] Cliente '$client_name' creado: $clients_dir/$client_name.ovpn${NC}"
    sleep 2
}

menu_openvpn() {
    while true; do
        mostrar_banner
        local svc=$( systemctl is-active openvpn@server 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── OPENVPN ─────────────────────────────────${NC}"
        echo -e "  OpenVPN: $(estado $svc)"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar OpenVPN"
        echo -e "  ${YELLOW}2)${NC}  Crear cliente (.ovpn)"
        echo -e "  ${YELLOW}3)${NC}  Listar clientes"
        echo -e "  ${YELLOW}4)${NC}  Reiniciar OpenVPN"
        echo -e "  ${YELLOW}5)${NC}  Ver estado"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_openvpn ;;
            2) crear_cliente_openvpn ;;
            3) ls -la /etc/openvpn/clients/*.ovpn 2>/dev/null || echo -e "${YELLOW}  No hay clientes.${NC}"; read -p "  Enter..." ;;
            4) systemctl restart openvpn@server && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            5) systemctl status openvpn@server --no-pager; read -p "  Enter..." ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   BROOK
# ════════════════════════════════════════════════════════════
BROOK_CONFIG="/etc/ctmanager/config/brook.conf"
BROOK_BIN="/usr/local/bin/brook"

instalar_brook() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Brook WS/WSS...${NC}"
    pkg_install nginx "$(pkg_name certbot)" "$(pkg_name certbot_nginx)" curl

    echo -e "${YELLOW}"
    read -p "  Dominio (ej: brook.midominio.com): " domain
    read -p "  Contraseña Brook: " brook_pass
    read -p "  Puerto interno Brook [default 9090]: " brook_port
    [ -z "$brook_port" ] && brook_port=9090
    echo -e "${NC}"

    echo -e "${YELLOW}  [*] Descargando Brook...${NC}"
    local latest_url=$(curl -s https://api.github.com/repos/txthinking/brook/releases/latest | \
        grep "browser_download_url.*brook_linux_amd64" | cut -d '"' -f 4)
    curl -L "$latest_url" -o "$BROOK_BIN" 2>/dev/null && chmod +x "$BROOK_BIN"

    cat > /etc/systemd/system/brook.service <<EOF
[Unit]
Description=CTManager Brook WSServer
After=network.target
[Service]
ExecStart=$BROOK_BIN wsserver -l 127.0.0.1:$brook_port -p $brook_pass
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable brook > /dev/null 2>&1
    systemctl start brook

    mkdir -p "$(dirname $BROOK_CONFIG)"
    cat > "$BROOK_CONFIG" <<EOF
DOMAIN="$domain"
BROOK_PASS="$brook_pass"
BROOK_PORT="$brook_port"
EOF
    echo -e "${GREEN}  [✓] Brook instalado. Puerto interno: $brook_port${NC}"
    send_telegram "✅ <b>Brook instalado</b>%0ADominio: $domain"
    sleep 2
}

menu_brook() {
    while true; do
        mostrar_banner
        local svc=$( systemctl is-active brook 2>/dev/null )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── BROOK WS/WSS ────────────────────────────${NC}"
        echo -e "  Brook: $(estado $svc)"
        if [ -f "$BROOK_CONFIG" ]; then
            source "$BROOK_CONFIG"
            echo -e "  Dominio: ${YELLOW}$DOMAIN${NC}  Puerto: ${YELLOW}$BROOK_PORT${NC}"
        fi
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar Brook"
        echo -e "  ${YELLOW}2)${NC}  Ver configuración"
        echo -e "  ${YELLOW}3)${NC}  Reiniciar Brook"
        echo -e "  ${YELLOW}4)${NC}  Desinstalar Brook"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_brook ;;
            2)
                [ -f "$BROOK_CONFIG" ] && source "$BROOK_CONFIG"
                echo -e "\n  ${GREEN}Dominio:${NC} $DOMAIN"
                echo -e "  ${GREEN}Contraseña:${NC} $BROOK_PASS"
                echo -e "  ${GREEN}Puerto:${NC} $BROOK_PORT"
                read -p "  Enter..."
                ;;
            3) systemctl restart brook && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            4)
                systemctl stop brook; systemctl disable brook > /dev/null 2>&1
                rm -f /etc/systemd/system/brook.service "$BROOK_BIN" "$BROOK_CONFIG"
                systemctl daemon-reload
                echo -e "${GREEN}  [✓] Brook desinstalado.${NC}"; sleep 2
                ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   PSIPHON
# ════════════════════════════════════════════════════════════
PSIPHON_DIR="/etc/ctmanager/psiphon"
PSIPHON_HEX="$PSIPHON_DIR/server_data.hex"

instalar_psiphon() {
    mostrar_banner
    echo -e "${CYAN}  [*] Instalando Psiphon...${NC}"
    pkg_install jq screen curl

    mkdir -p "$PSIPHON_DIR" && cd "$PSIPHON_DIR"
    echo -e "${YELLOW}  [*] Descargando binario Psiphond...${NC}"
    wget -q 'https://docs.google.com/uc?export=download&id=1Cg_YsTDt_aqK_EXbnzP9tRFSyFe_7N-m' -O 'psiphond'
    chmod 775 psiphond

    echo -e "${YELLOW}"
    read -p "  Puerto FRONTED-MEEK-HTTP-OSSH (ej: 80): " httposh
    read -p "  Puerto FRONTED-MEEK-OSSH (ej: 443): " osh
    echo -e "${NC}"

    ./psiphond --ipaddress 0.0.0.0 \
        --protocol FRONTED-MEEK-HTTP-OSSH:"$httposh" \
        --protocol FRONTED-MEEK-OSSH:"$osh" generate > /dev/null 2>&1

    screen -dmS psiserver ./psiphond run
    cat "$PSIPHON_DIR/server-entry.dat" > "$PSIPHON_HEX" 2>/dev/null
    echo -e "${GREEN}  [✓] Psiphon instalado y corriendo en Screen.${NC}"
    send_telegram "✅ <b>Psiphon instalado</b>%0APuertos: $httposh / $osh"
    sleep 2
}

menu_psiphon() {
    while true; do
        mostrar_banner
        local psi=$( pgrep -f "psiphond run" > /dev/null 2>&1 && echo "active" || echo "inactive" )
        estado() { [ "$1" = "active" ] && echo -e "${GREEN}● Activo${NC}" || echo -e "${RED}● Inactivo${NC}"; }
        echo -e "  ${CYAN}── PSIPHON ─────────────────────────────────${NC}"
        echo -e "  Psiphon: $(estado $psi)"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Instalar Psiphon"
        echo -e "  ${YELLOW}2)${NC}  Ver código HEX/Base64"
        echo -e "  ${YELLOW}3)${NC}  Reiniciar Psiphon"
        echo -e "  ${YELLOW}4)${NC}  Ver logs (Screen)"
        echo -e "  ${YELLOW}5)${NC}  Desinstalar"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) instalar_psiphon ;;
            2)
                if [ -f "$PSIPHON_HEX" ]; then
                    local hex=$(cat "$PSIPHON_HEX" | tr -d '\n\r ')
                    local decoded=$(echo "$hex" | xxd -r -p 2>/dev/null)
                    local b64=$(echo -n "$decoded" | base64 -w 0 2>/dev/null)
                    echo -e "\n  ${GREEN}Base64/JSON:${NC}"
                    echo -e "  ${CYAN}[\"$b64\"]${NC}\n"
                fi
                read -p "  Enter..."
                ;;
            3)
                killall psiphond > /dev/null 2>&1
                cd "$PSIPHON_DIR" && screen -dmS psiserver ./psiphond run
                echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1
                ;;
            4) screen -r psiserver; read -p "  Enter..." ;;
            5)
                killall psiphond > /dev/null 2>&1
                rm -rf "$PSIPHON_DIR"
                echo -e "${GREEN}  [✓] Psiphon desinstalado.${NC}"; sleep 2
                ;;
            0) break ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   CONFIGURACIÓN GENERAL
# ════════════════════════════════════════════════════════════
configurar_telegram() {
    mostrar_banner
    echo -e "  ${CYAN}── CONFIGURAR NOTIFICACIONES TELEGRAM ──${NC}"
    echo ""
    echo -e "  ${YELLOW}Token: obtené de @BotFather"
    echo -e "  Chat ID: obtené de @userinfobot${NC}"
    echo ""
    read -p "  Token del Bot: " token
    read -p "  Chat ID: " chat_id
    mkdir -p "$CONFIG_DIR"
    cat > "$TG_CONFIG" <<EOF
TG_TOKEN="$token"
TG_CHAT_ID="$chat_id"
EOF
    send_telegram "✅ <b>CTManager conectado</b>%0ANotificaciones activas."
    echo -e "${GREEN}  [✓] Telegram configurado y mensaje de prueba enviado.${NC}"
    sleep 2
}

mostrar_estadisticas() {
    mostrar_banner
    echo -e "  ${CYAN}── ESTADÍSTICAS DEL SERVIDOR ──${NC}"
    echo ""
    local ip=$(curl -s ipv4.icanhazip.com 2>/dev/null)
    echo -e "  ${YELLOW}Sistema:${NC}"
    echo -e "  IP Pública : ${GREEN}$ip${NC}"
    echo -e "  Uptime     : ${GREEN}$(uptime -p)${NC}"
    echo -e "  RAM        : ${GREEN}$(free -m | awk '/Mem:/ {printf "%.0f MB / %.0f MB", $3, $2}')${NC}"
    echo -e "  Disco      : ${GREEN}$(df -h / | awk 'NR==2 {printf "%s / %s", $3, $2}')${NC}"
    echo -e "  CPU        : ${GREEN}$(cat /proc/loadavg | awk '{print $1, $2, $3}')${NC}"
    echo ""
    echo -e "  ${YELLOW}Servicios:${NC}"
    for svc in hysteria-v1 hysteria-v2 ctmanager-ws dropbear "$(stunnel_svc)" openvpn@server slowdns brook udp-custom; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}●${NC} $svc"
        else
            echo -e "  ${RED}●${NC} $svc"
        fi
    done
    echo ""
    read -p "  Presioná Enter para continuar..."
}

# ════════════════════════════════════════════════════════════
#   MENÚ PRINCIPAL
# ════════════════════════════════════════════════════════════
menu_principal() {
    while true; do
        mostrar_banner
        mostrar_estados

        echo -e "  ${CYAN}── PROTOCOLOS ───────────────────────────────${NC}"
        echo -e "  ${YELLOW}1)${NC}   Hysteria V1/V2"
        echo -e "  ${YELLOW}2)${NC}   WebSocket + SOCKS Python"
        echo -e "  ${YELLOW}3)${NC}   BadVPN / UDP-Custom"
        echo -e "  ${YELLOW}4)${NC}   SlowDNS / DNSTT"
        echo -e "  ${YELLOW}5)${NC}   Psiphon"
        echo -e "  ${YELLOW}6)${NC}   Brook (WS/WSS)"
        echo -e "  ${YELLOW}7)${NC}   Dropbear"
        echo -e "  ${YELLOW}8)${NC}   Stunnel SSL"
        echo -e "  ${YELLOW}9)${NC}   OpenVPN"
        echo ""
        echo -e "  ${CYAN}── CONFIGURACIÓN ────────────────────────────${NC}"
        echo -e "  ${YELLOW}10)${NC}  Estadísticas del servidor"
        echo -e "  ${YELLOW}11)${NC}  Configurar Telegram"
        echo ""
        echo -e "  ${RED}0)${NC}   Salir"
        echo -e "  ${CYAN}─────────────────────────────────────────────${NC}"
        echo ""
        read -p "  Seleccioná una opción: " opcion

        case $opcion in
            1)  menu_hysteria ;;
            2)  menu_websocket_socks ;;
            3)  menu_badvpn ;;
            4)  menu_slowdns ;;
            5)  menu_psiphon ;;
            6)  menu_brook ;;
            7)  menu_dropbear ;;
            8)  menu_stunnel ;;
            9)  menu_openvpn ;;
            10) mostrar_estadisticas ;;
            11) configurar_telegram ;;
            0)  echo -e "${CYAN}  ¡Hasta luego!${NC}"; exit 0 ;;
            *)  echo -e "${RED}  Opción inválida.${NC}"; sleep 1 ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════
#   INICIO
# ════════════════════════════════════════════════════════════
mkdir -p "$BASE_DIR" "$SCRIPTS_DIR" "$LOGS_DIR" "$CONFIG_DIR"
init_db_hysteria "$DB_V1"
init_db_hysteria "$DB_V2"
init_db_ws
init_db_socks

# Instalar comando global
cp "$0" "$MANAGER_PATH" 2>/dev/null
chmod +x "$MANAGER_PATH" 2>/dev/null

menu_principal
