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
        mb_limit INTEGER DEFAULT 0,
        mb_usado INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        last_seen TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
    # Agregar columnas si no existen (para BDs viejas)
    sqlite3 "$WS_DB" "ALTER TABLE users ADD COLUMN mb_limit INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$WS_DB" "ALTER TABLE users ADD COLUMN mb_usado INTEGER DEFAULT 0;" 2>/dev/null || true
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

    # Crear servidor WebSocket/HTTP Python (túnel transparente)
    cat > "$WS_SERVER" << 'PYEOF'
#!/usr/bin/env python3
# CTManager WebSocket/HTTP Proxy - by CHARLY_TRICKS
# Túnel transparente: redirige al SSH/Dropbear sin autenticación propia
import socket, threading, json, sys, os

CONFIG_FILE = "/etc/ctmanager/websocket/config.json"

def load_config():
    try:
        with open(CONFIG_FILE) as f:
            return json.load(f)
    except:
        return {"target_host": "127.0.0.1", "target_port": 22, "payload": "200"}

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
        "200": b"HTTP/1.1 200 OK
Content-Length: 0

",
        "101": b"HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade

"
    }
    payload = payloads.get(str(cfg.get("payload", "200")), payloads["200"])
    target_host = cfg.get("target_host", "127.0.0.1")
    target_port = int(cfg.get("target_port", 22))
    try:
        # Leer request del cliente
        data = client_socket.recv(4096)
        if not data:
            client_socket.close()
            return
        # Enviar payload de respuesta
        client_socket.sendall(payload)
        # Conectar al destino (SSH/Dropbear)
        dest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dest.connect((target_host, target_port))
        # Puente bidireccional transparente
        threading.Thread(target=forward, args=(client_socket, dest), daemon=True).start()
        threading.Thread(target=forward, args=(dest, client_socket), daemon=True).start()
    except Exception as e:
        try: client_socket.close()
        except: pass

def start_server(port, cfg):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(('0.0.0.0', port))
        srv.listen(200)
        print(f"[CTManager WS] Puerto {port} -> {cfg.get('target_host')}:{cfg.get('target_port')} | Payload: HTTP {cfg.get('payload','200')}")
        while True:
            client, addr = srv.accept()
            threading.Thread(target=handle_client, args=(client, cfg), daemon=True).start()
    except OSError as e:
        print(f"[CTManager WS] Error puerto {port}: {e}")

if __name__ == "__main__":
    cfg = load_config()
    ports = []
    if cfg.get("enable_ws", True) and cfg.get("ws_port"):
        ports.append(int(cfg["ws_port"]))
    if cfg.get("enable_wss", True) and cfg.get("wss_port"):
        ports.append(int(cfg["wss_port"]))
    if not ports:
        ports = [8080]
    threads = []
    for p in set(ports):  # set() evita duplicados
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
# CTManager SOCKS Injector - by CHARLY_TRICKS
# Túnel transparente: redirige al SSH/Dropbear sin autenticación propia
import socket, threading, sys

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

def handle_client(client_socket, dest_host, dest_port, payload_code):
    payloads = {
        "200": b"HTTP/1.1 200 OK
Content-Length: 0

",
        "101": b"HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade

"
    }
    payload = payloads.get(payload_code, payloads["200"])
    try:
        # Leer request del cliente
        data = client_socket.recv(4096)
        if not data:
            client_socket.close()
            return
        # Enviar payload de respuesta
        client_socket.sendall(payload)
        # Conectar al destino (SSH/Dropbear)
        dest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dest.connect((dest_host, dest_port))
        # Puente bidireccional transparente
        threading.Thread(target=forward, args=(client_socket, dest), daemon=True).start()
        threading.Thread(target=forward, args=(dest, client_socket), daemon=True).start()
    except Exception as e:
        try: client_socket.close()
        except: pass

def start(listen_port, dest_host, dest_port, payload_code):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(('0.0.0.0', listen_port))
        srv.listen(200)
        print(f"[CTManager SOCKS] Puerto {listen_port} -> {dest_host}:{dest_port} | Payload: HTTP {payload_code}")
        while True:
            client, addr = srv.accept()
            threading.Thread(target=handle_client, args=(client, dest_host, dest_port, payload_code), daemon=True).start()
    except OSError as e:
        print(f"[CTManager SOCKS] Error puerto {listen_port}: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Uso: proxy.py <puerto> <host_destino> <puerto_destino> <payload_code>")
        sys.exit(1)
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
        echo -e "  ${YELLOW}1)${NC}  Instalar / Reinstalar WebSocket"
        echo -e "  ${YELLOW}2)${NC}  Gestionar puertos y configuración"
        echo -e "  ${YELLOW}3)${NC}  Agregar usuario"
        echo -e "  ${YELLOW}4)${NC}  Ver usuarios"
        echo -e "  ${YELLOW}5)${NC}  Renovar / Agregar días"
        echo -e "  ${YELLOW}6)${NC}  Cambiar límite de MB"
        echo -e "  ${YELLOW}7)${NC}  Resetear MB usado"
        echo -e "  ${YELLOW}8)${NC}  Activar / Desactivar usuario"
        echo -e "  ${YELLOW}9)${NC}  Eliminar usuario"
        echo -e "  ${YELLOW}10)${NC} Reiniciar WebSocket"
        echo -e "  ${YELLOW}11)${NC} Ver logs WebSocket"
        echo ""
        echo -e "  ${CYAN}── SOCKS PYTHON ──────────────────────────${NC}"
        echo -e "  ${YELLOW}12)${NC} Instalar SOCKS Injector"
        echo -e "  ${YELLOW}13)${NC} Agregar usuario SOCKS"
        echo -e "  ${YELLOW}14)${NC} Editar usuario SOCKS"
        echo -e "  ${YELLOW}15)${NC} Eliminar usuario SOCKS"
        echo -e "  ${YELLOW}16)${NC} Ver usuarios SOCKS"
        echo -e "  ${YELLOW}17)${NC} Ver servicios SOCKS"
        echo -e "  ${YELLOW}18)${NC} Detener todos los SOCKS"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1)  instalar_websocket ;;
            2)  gestionar_puertos_ws ;;
            3)  agregar_usuario_ws ;;
            4)  ver_usuarios_ws ;;
            5)  renovar_usuario_ws ;;
            6)  cambiar_limite_mb_ws ;;
            7)  resetear_mb_ws ;;
            8)  activar_desactivar_ws ;;
            9)  eliminar_usuario_ws ;;
            10) systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Reiniciado.${NC}"; sleep 1 ;;
            11) journalctl -u ctmanager-ws -n 50 --no-pager; read -p "Enter..." ;;
            12) instalar_socks ;;
            13) agregar_usuario_socks ;;
            14) editar_usuario_socks ;;
            15) eliminar_usuario_socks ;;
            16) ver_usuarios_socks ;;
            17) listar_socks ;;
            18) detener_socks ;;
            0)  break ;;
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
    read -p "  Máx conexiones simultáneas [3]: " max_conn
    [ -z "$max_conn" ] && max_conn=3
    read -p "  Límite de MB (0 = sin límite): " mb_limit
    [ -z "$mb_limit" ] && mb_limit=0
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires="datetime('now', '+${dias} days')"
        expires_show=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null)
    else
        expires="NULL"; expires_show="Sin límite"
    fi
    sqlite3 "$WS_DB" "INSERT INTO users (username, password, max_connections, mb_limit, expires_at) VALUES ('$username', '$password', $max_conn, $mb_limit, $expires);" 2>/dev/null
    [ $? -eq 0 ] && echo -e "${GREEN}  [✓] Usuario '$username' agregado. Expira: $expires_show | MB: $mb_limit${NC}" || echo -e "${RED}  [✗] Error: usuario ya existe.${NC}"
    sleep 2
}

ver_usuarios_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS WEBSOCKET ──${NC}"
    echo ""
    printf "  %-3s %-16s %-12s %-5s %-8s %-8s %-14s %-6s\n" "ID" "USUARIO" "CONTRASEÑA" "CONN" "MB LIM" "MB USO" "EXPIRA" "EST"
    echo "  ──────────────────────────────────────────────────────────────────────────"
    while IFS='|' read -r id user pass max mb_lim mb_uso expires activo; do
        estado=$( [ "$activo" = "1" ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}" )
        mb_lim_s=$( [ "$mb_lim" = "0" ] && echo "Libre" || echo "${mb_lim}MB" )
        printf "  %-3s ${CYAN}%-16s${NC} %-12s %-5s %-8s %-8s %-14s %b\n" \
            "$id" "$user" "$pass" "$max" "$mb_lim_s" "${mb_uso}MB" "${expires:-Sin límite}" "$estado"
    done < <(sqlite3 "$WS_DB" "SELECT id, username, password, max_connections, COALESCE(mb_limit,0), COALESCE(mb_usado,0), COALESCE(expires_at,'Sin límite'), activo FROM users;" 2>/dev/null)
    echo ""
    read -p "  Presioná Enter para continuar..."
}

renovar_usuario_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── RENOVAR / AGREGAR DÍAS ──${NC}"
    ver_usuarios_ws
    echo -e "${YELLOW}"
    read -p "  Usuario a renovar: " username
    read -p "  Días a agregar: " dias
    echo -e "${NC}"
    sqlite3 "$WS_DB" "UPDATE users SET
        expires_at = CASE
            WHEN expires_at IS NULL OR expires_at < datetime('now')
                THEN datetime('now', '+${dias} days')
            ELSE datetime(expires_at, '+${dias} days')
        END,
        activo = 1
        WHERE username='$username';" 2>/dev/null
    local nueva=$(sqlite3 "$WS_DB" "SELECT expires_at FROM users WHERE username='$username';" 2>/dev/null)
    echo -e "${GREEN}  [✓] $dias días agregados a '$username'. Nueva expiración: $nueva${NC}"
    sleep 2
}

resetear_mb_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── RESETEAR MB USADO ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario (o 'todos' para todos): " username
    echo -e "${NC}"
    if [ "$username" = "todos" ]; then
        sqlite3 "$WS_DB" "UPDATE users SET mb_usado=0;" 2>/dev/null
        echo -e "${GREEN}  [✓] MB reseteado para todos los usuarios.${NC}"
    else
        sqlite3 "$WS_DB" "UPDATE users SET mb_usado=0 WHERE username='$username';" 2>/dev/null
        echo -e "${GREEN}  [✓] MB reseteado para '$username'.${NC}"
    fi
    sleep 2
}

cambiar_limite_mb_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── CAMBIAR LÍMITE DE MB ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Nuevo límite MB (0 = sin límite): " mb
    echo -e "${NC}"
    sqlite3 "$WS_DB" "UPDATE users SET mb_limit=$mb WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Límite de '$username' actualizado a ${mb}MB.${NC}"
    sleep 2
}

activar_desactivar_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── ACTIVAR / DESACTIVAR USUARIO ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    echo -e "${NC}"
    local activo=$(sqlite3 "$WS_DB" "SELECT activo FROM users WHERE username='$username';" 2>/dev/null)
    if [ "$activo" = "1" ]; then
        sqlite3 "$WS_DB" "UPDATE users SET activo=0 WHERE username='$username';" 2>/dev/null
        echo -e "${YELLOW}  [!] Usuario '$username' desactivado.${NC}"
    else
        sqlite3 "$WS_DB" "UPDATE users SET activo=1 WHERE username='$username';" 2>/dev/null
        echo -e "${GREEN}  [✓] Usuario '$username' activado.${NC}"
    fi
    systemctl restart ctmanager-ws 2>/dev/null
    sleep 2
}

eliminar_usuario_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── ELIMINAR USUARIO WEBSOCKET ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario a eliminar: " username
    echo -e "${NC}"
    sqlite3 "$WS_DB" "DELETE FROM users WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Usuario '$username' eliminado.${NC}"
    send_telegram "🗑️ <b>Usuario WS eliminado</b>%0AUsuario: $username"
    sleep 2
}

gestionar_puertos_ws() {
    mostrar_banner
    echo -e "  ${CYAN}── GESTIÓN DE PUERTOS WEBSOCKET ──${NC}"
    echo ""
    local ws_port=$(python3 -c "import json; print(json.load(open('$WS_CONFIG')).get('ws_port',''))" 2>/dev/null)
    local wss_port=$(python3 -c "import json; print(json.load(open('$WS_CONFIG')).get('wss_port',''))" 2>/dev/null)
    local target=$(python3 -c "import json; d=json.load(open('$WS_CONFIG')); print(str(d.get('target_host',''))+':'+str(d.get('target_port','')))" 2>/dev/null)
    local payload=$(python3 -c "import json; print(json.load(open('$WS_CONFIG')).get('payload','200'))" 2>/dev/null)
    echo -e "  Puerto WS actual  : ${YELLOW}$ws_port${NC}"
    echo -e "  Puerto WSS actual : ${YELLOW}$wss_port${NC}"
    echo -e "  Destino TCP       : ${YELLOW}$target${NC}"
    echo -e "  Payload           : ${YELLOW}HTTP $payload${NC}"
    echo ""
    echo -e "  ${YELLOW}1)${NC} Cambiar puerto WS"
    echo -e "  ${YELLOW}2)${NC} Cambiar puerto WSS"
    echo -e "  ${YELLOW}3)${NC} Cambiar destino TCP"
    echo -e "  ${YELLOW}4)${NC} Cambiar payload (200/101)"
    echo -e "  ${YELLOW}5)${NC} Activar/Desactivar WS"
    echo -e "  ${YELLOW}6)${NC} Activar/Desactivar WSS"
    echo -e "  ${RED}0)${NC} Volver"
    echo ""
    read -p "  Opción: " op
    case $op in
        1)
            read -p "  Nuevo puerto WS: " val
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['ws_port']=$val; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Puerto WS cambiado a $val${NC}"
            ;;
        2)
            read -p "  Nuevo puerto WSS: " val
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['wss_port']=$val; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Puerto WSS cambiado a $val${NC}"
            ;;
        3)
            echo "  1) SSH(22)  2) Dropbear(443)  3) Dropbear(80)  4) Manual"
            read -p "  Opción: " dest_opt
            case $dest_opt in
                1) th="127.0.0.1"; tp=22 ;;
                2) th="127.0.0.1"; tp=443 ;;
                3) th="127.0.0.1"; tp=80 ;;
                *) read -p "  Host: " th; read -p "  Puerto: " tp ;;
            esac
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['target_host']='$th'; cfg['target_port']=$tp; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Destino cambiado a $th:$tp${NC}"
            ;;
        4)
            echo "  1) HTTP 200 OK  2) HTTP 101 Switching Protocols"
            read -p "  Opción: " po
            [ "$po" = "2" ] && pval="101" || pval="200"
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['payload']='$pval'; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] Payload cambiado a HTTP $pval${NC}"
            ;;
        5)
            local enabled=$(python3 -c "import json; print(json.load(open('$WS_CONFIG')).get('enable_ws',True))" 2>/dev/null)
            [ "$enabled" = "True" ] && val="false" || val="true"
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['enable_ws']=$val=='true'; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] WS $([ "$val" = "true" ] && echo activado || echo desactivado).${NC}"
            ;;
        6)
            local enabled=$(python3 -c "import json; print(json.load(open('$WS_CONFIG')).get('enable_wss',True))" 2>/dev/null)
            [ "$enabled" = "True" ] && val="false" || val="true"
            python3 -c "import json; cfg=json.load(open('$WS_CONFIG')); cfg['enable_wss']=$val=='true'; json.dump(cfg,open('$WS_CONFIG','w'),indent=4)" 2>/dev/null
            systemctl restart ctmanager-ws && echo -e "${GREEN}  [✓] WSS $([ "$val" = "true" ] && echo activado || echo desactivado).${NC}"
            ;;
    esac
    sleep 2
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
        max_connections INTEGER DEFAULT 1,
        mb_limit INTEGER DEFAULT 0,
        mb_usado INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
    sqlite3 "$SOCKS_DB" "ALTER TABLE users ADD COLUMN mb_limit INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$SOCKS_DB" "ALTER TABLE users ADD COLUMN mb_usado INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$SOCKS_DB" "ALTER TABLE users ADD COLUMN max_connections INTEGER DEFAULT 1;" 2>/dev/null || true
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
#   GESTIÓN DE USUARIOS SSH
# ════════════════════════════════════════════════════════════
SSH_DB="/etc/ctmanager/config/ssh_users.db"

init_db_ssh() {
    mkdir -p "$CONFIG_DIR"
    sqlite3 "$SSH_DB" "CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now')),
        expires_at TEXT,
        activo INTEGER DEFAULT 1
    );" 2>/dev/null
}

crear_usuario_ssh() {
    mostrar_banner
    init_db_ssh
    echo -e "  ${CYAN}── CREAR USUARIO SSH ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Contraseña: " password
    read -p "  Días de expiración (0 = sin límite): " dias
    echo -e "${NC}"

    # Crear usuario en el sistema
    if id "$username" &>/dev/null; then
        echo -e "${RED}  [!] El usuario '$username' ya existe en el sistema.${NC}"
    else
        useradd -m -s /bin/false "$username" 2>/dev/null || useradd -M -s /bin/false "$username" 2>/dev/null
        echo "$username:$password" | chpasswd
        echo -e "${GREEN}  [✓] Usuario '$username' creado en el sistema.${NC}"
    fi

    # Calcular expiración
    if [ "$dias" -gt 0 ] 2>/dev/null; then
        expires_show=$(date -d "+${dias} days" '+%Y-%m-%d' 2>/dev/null)
        expires_db="datetime('now', '+${dias} days')"
        # Expirar cuenta en el sistema
        chage -E "$expires_show" "$username" 2>/dev/null
    else
        expires_show="Sin límite"
        expires_db="NULL"
    fi

    # Guardar en BD
    sqlite3 "$SSH_DB" "INSERT OR REPLACE INTO users (username, password, expires_at) VALUES ('$username', '$password', $expires_db);" 2>/dev/null
    echo -e "${GREEN}  [✓] Usuario SSH '$username' listo. Expira: $expires_show${NC}"
    send_telegram "👤 <b>Usuario SSH creado</b>%0AUsuario: $username%0AExpira: $expires_show"
    sleep 2
}

ver_usuarios_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS SSH ──${NC}"
    echo ""
    printf "  %-3s %-16s %-14s %-20s %-8s
" "ID" "USUARIO" "CONTRASEÑA" "EXPIRA" "ESTADO"
    echo "  ──────────────────────────────────────────────────────────────────"
    while IFS='|' read -r id user pass expires activo; do
        estado=$( [ "$activo" = "1" ] && echo -e "${GREEN}Activo${NC}" || echo -e "${RED}Inactivo${NC}" )
        # Verificar si existe en el sistema
        id "$user" &>/dev/null && sys_ok="${GREEN}●${NC}" || sys_ok="${RED}●${NC}"
        printf "  %b %-3s ${CYAN}%-16s${NC} %-14s %-20s %b
"             "$sys_ok" "$id" "$user" "$pass" "${expires:-Sin límite}" "$estado"
    done < <(sqlite3 "$SSH_DB" "SELECT id, username, password, COALESCE(expires_at,'Sin límite'), activo FROM users;" 2>/dev/null)
    echo ""
    read -p "  Presioná Enter para continuar..."
}

cambiar_password_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── CAMBIAR CONTRASEÑA SSH ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    read -p "  Nueva contraseña: " password
    echo -e "${NC}"
    echo "$username:$password" | chpasswd 2>/dev/null
    sqlite3 "$SSH_DB" "UPDATE users SET password='$password' WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Contraseña de '$username' actualizada.${NC}"
    sleep 2
}

renovar_usuario_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── RENOVAR / AGREGAR DÍAS SSH ──${NC}"
    ver_usuarios_ssh
    echo -e "${YELLOW}"
    read -p "  Usuario a renovar: " username
    read -p "  Días a agregar: " dias
    echo -e "${NC}"
    # Calcular nueva fecha
    local actual=$(sqlite3 "$SSH_DB" "SELECT expires_at FROM users WHERE username='$username';" 2>/dev/null)
    sqlite3 "$SSH_DB" "UPDATE users SET
        expires_at = CASE
            WHEN expires_at IS NULL OR expires_at < datetime('now')
                THEN datetime('now', '+${dias} days')
            ELSE datetime(expires_at, '+${dias} days')
        END,
        activo = 1
        WHERE username='$username';" 2>/dev/null
    local nueva=$(sqlite3 "$SSH_DB" "SELECT expires_at FROM users WHERE username='$username';" 2>/dev/null)
    # Actualizar expiración en el sistema
    local nueva_date=$(echo "$nueva" | cut -d' ' -f1)
    chage -E "$nueva_date" "$username" 2>/dev/null
    # Activar cuenta si estaba bloqueada
    usermod -U "$username" 2>/dev/null
    echo -e "${GREEN}  [✓] $dias días agregados. Nueva expiración: $nueva${NC}"
    send_telegram "🔄 <b>Usuario SSH renovado</b>%0AUsuario: $username%0ANueva exp: $nueva"
    sleep 2
}

eliminar_usuario_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── ELIMINAR USUARIO SSH ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario a eliminar: " username
    read -p "  ¿Eliminar también su directorio home? (s/n): " del_home
    echo -e "${NC}"
    if [ "$del_home" = "s" ]; then
        userdel -r "$username" 2>/dev/null
    else
        userdel "$username" 2>/dev/null
    fi
    sqlite3 "$SSH_DB" "DELETE FROM users WHERE username='$username';" 2>/dev/null
    echo -e "${GREEN}  [✓] Usuario '$username' eliminado.${NC}"
    send_telegram "🗑️ <b>Usuario SSH eliminado</b>%0AUsuario: $username"
    sleep 2
}

activar_desactivar_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── ACTIVAR / BLOQUEAR USUARIO SSH ──${NC}"
    echo -e "${YELLOW}"
    read -p "  Usuario: " username
    echo -e "${NC}"
    local activo=$(sqlite3 "$SSH_DB" "SELECT activo FROM users WHERE username='$username';" 2>/dev/null)
    if [ "$activo" = "1" ]; then
        usermod -L "$username" 2>/dev/null
        sqlite3 "$SSH_DB" "UPDATE users SET activo=0 WHERE username='$username';" 2>/dev/null
        echo -e "${YELLOW}  [!] Usuario '$username' bloqueado.${NC}"
    else
        usermod -U "$username" 2>/dev/null
        sqlite3 "$SSH_DB" "UPDATE users SET activo=1 WHERE username='$username';" 2>/dev/null
        echo -e "${GREEN}  [✓] Usuario '$username' desbloqueado.${NC}"
    fi
    sleep 2
}

verificar_expirados_ssh() {
    mostrar_banner
    echo -e "  ${CYAN}── USUARIOS EXPIRADOS ──${NC}"
    echo ""
    local expirados=$(sqlite3 "$SSH_DB" "SELECT username FROM users WHERE expires_at IS NOT NULL AND expires_at < datetime('now') AND activo=1;" 2>/dev/null)
    if [ -z "$expirados" ]; then
        echo -e "  ${GREEN}No hay usuarios expirados.${NC}"
    else
        echo -e "  ${RED}Usuarios expirados:${NC}"
        for user in $expirados; do
            echo -e "  ${RED}●${NC} $user"
            usermod -L "$user" 2>/dev/null
            sqlite3 "$SSH_DB" "UPDATE users SET activo=0 WHERE username='$user';" 2>/dev/null
        done
        echo -e "
  ${YELLOW}[!] Usuarios bloqueados automáticamente.${NC}"
    fi
    echo ""
    read -p "  Presioná Enter para continuar..."
}

menu_ssh() {
    while true; do
        mostrar_banner
        local total=$(sqlite3 "$SSH_DB" "SELECT COUNT(*) FROM users WHERE activo=1;" 2>/dev/null || echo "0")
        local expirados=$(sqlite3 "$SSH_DB" "SELECT COUNT(*) FROM users WHERE expires_at IS NOT NULL AND expires_at < datetime('now');" 2>/dev/null || echo "0")
        echo -e "  ${CYAN}── GESTIÓN DE USUARIOS SSH ─────────────────${NC}"
        echo -e "  Usuarios activos: ${GREEN}$total${NC}  |  Expirados: ${RED}$expirados${NC}"
        echo ""
        echo -e "  ${YELLOW}1)${NC}  Crear usuario SSH"
        echo -e "  ${YELLOW}2)${NC}  Ver usuarios"
        echo -e "  ${YELLOW}3)${NC}  Cambiar contraseña"
        echo -e "  ${YELLOW}4)${NC}  Renovar / Agregar días"
        echo -e "  ${YELLOW}5)${NC}  Activar / Bloquear usuario"
        echo -e "  ${YELLOW}6)${NC}  Eliminar usuario"
        echo -e "  ${YELLOW}7)${NC}  Ver y bloquear expirados"
        echo -e "  ${RED}0)${NC}  Volver"
        echo ""
        read -p "  Opción: " op
        case $op in
            1) crear_usuario_ssh ;;
            2) ver_usuarios_ssh ;;
            3) cambiar_password_ssh ;;
            4) renovar_usuario_ssh ;;
            5) activar_desactivar_ssh ;;
            6) eliminar_usuario_ssh ;;
            7) verificar_expirados_ssh ;;
            0) break ;;
        esac
    done
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
        echo -e "  ${CYAN}── USUARIOS ─────────────────────────────────${NC}"
        echo -e "  ${YELLOW}10)${NC}  Gestión de usuarios SSH"
        echo ""
        echo -e "  ${CYAN}── CONFIGURACIÓN ────────────────────────────${NC}"
        echo -e "  ${YELLOW}11)${NC}  Estadísticas del servidor"
        echo -e "  ${YELLOW}12)${NC}  Configurar Telegram"
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
            10) menu_ssh ;;
            11) mostrar_estadisticas ;;
            12) configurar_telegram ;;
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
init_db_ssh

# Instalar comando global
cp "$0" "$MANAGER_PATH" 2>/dev/null
chmod +x "$MANAGER_PATH" 2>/dev/null

menu_principal
