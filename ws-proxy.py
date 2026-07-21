#!/usr/bin/env python3
# ============================================================
#  CTManager WebSocket / HTTP Proxy  -  by CHARLY_TRICKS
#  Version corregida.
#
#  Tunel transparente: recibe la conexion, contesta el payload
#  HTTP que espera la app (200 o 101) y despues hace de puente
#  hacia el SSH/Dropbear local. La autenticacion real la hace
#  el sshd, este proceso no valida usuarios.
#
#  Lee /etc/ctmanager/websocket/config.json
# ============================================================
import socket
import threading
import json
import sys

CONFIG_FILE = "/etc/ctmanager/websocket/config.json"

DEFAULTS = {
    "ws_port": 80,
    "wss_port": 443,
    "target_host": "127.0.0.1",
    "target_port": 22,
    "payload": "101",
    "enable_ws": True,
    "enable_wss": True,
    # Si V2Ray esta instalado, los pedidos a esta ruta se derivan
    # a Xray en vez de al SSH. Asi los dos comparten el puerto 80.
    "vless_path": "",
    "vless_port": 0,
    # Mapa ruta -> puerto local. Permite tener VLESS y VMess
    # conviviendo en el mismo puerto 80, cada uno en su ruta.
    "rutas": {},
    # Puerto local donde Xray escucha TLS. El proxy detecta el
    # saludo TLS por el primer byte y deriva ahi, asi el 443
    # sirve para SSH sin cifrar y para V2Ray con TLS a la vez.
    "tls_port": 0,
}

# Los \r\n van escapados. Este era el bug de la version anterior:
# tenia saltos de linea reales y Python no podia leer el archivo.
PAYLOADS = {
    "200": b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
    "101": b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
}


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG_FILE) as f:
            cfg.update(json.load(f))
    except Exception as e:
        print(f"[CTManager WS] No se pudo leer {CONFIG_FILE}: {e}", flush=True)
        print("[CTManager WS] Usando valores por defecto.", flush=True)
    return cfg


def forward(src, dst):
    """Copia bytes de un socket al otro hasta que se corte."""
    try:
        while True:
            data = src.recv(8192)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.close()
            except Exception:
                pass


def ruta_del_pedido(data):
    """Devuelve la ruta pedida en la primera linea HTTP, o cadena vacia."""
    try:
        primera = data.split(b"\r\n", 1)[0].decode("latin-1")
        partes = primera.split(" ")
        if len(partes) >= 2:
            return partes[1].split("?")[0]
    except Exception:
        pass
    return ""


def parece_http(data):
    """True si el bloque recibido es un request HTTP y no SSH."""
    if data[:4] == b"SSH-":
        return False
    inicio = data[:8].upper()
    for verbo in (b"GET", b"POST", b"HEAD", b"PUT", b"OPTIONS",
                  b"CONNECT", b"DELETE", b"TRACE", b"PATCH"):
        if inicio.startswith(verbo):
            return True
    return b"HTTP/" in data[:64].upper()


def handle_client(client, cfg):
    payload = PAYLOADS.get(str(cfg.get("payload", "101")), PAYLOADS["101"])
    host = cfg.get("target_host", "127.0.0.1")
    port = int(cfg.get("target_port", 22))
    dest = None
    pendiente = b""
    destino_v2ray = 0
    rutas = dict(cfg.get("rutas") or {})
    # Compatibilidad con configuraciones viejas
    if not rutas and cfg.get("vless_path") and cfg.get("vless_port"):
        rutas[str(cfg["vless_path"])] = int(cfg["vless_port"])
    try:
        client.settimeout(20)

        # Algunas apps (HTTP Custom entre ellas) mandan MAS DE UN
        # request antes de empezar el SSH. Hay que contestarle a
        # todos. Si en vez de eso reenviaramos el segundo request al
        # sshd, este responde "Invalid SSH identification string" y
        # la app lo lee como tamano de paquete -> "Illegal packet size".
        for _ in range(5):
            try:
                data = client.recv(8192)
            except socket.timeout:
                data = b""
            if not data:
                break

            # 0x16 = inicio de un saludo TLS. No es HTTP: va derecho
            # a Xray, que es quien tiene el certificado.
            if data[:1] == b"\x16" and int(cfg.get("tls_port") or 0):
                destino_v2ray = int(cfg["tls_port"])
                pendiente = data
                break

            if parece_http(data):
                # Si el pedido va a la ruta de V2Ray, no contestamos
                # nosotros: el saludo WebSocket lo tiene que dar Xray.
                if rutas:
                    pedida = ruta_del_pedido(data)
                    destino = None
                    for ruta, puerto in rutas.items():
                        if pedida == ruta or pedida.startswith(ruta + "/"):
                            destino = int(puerto)
                            break
                    if destino:
                        destino_v2ray = destino
                        pendiente = data
                        break
                client.sendall(payload)
                continue
            # Ya no es HTTP: esto es el saludo SSH, va al puente.
            pendiente = data
            break

        client.settimeout(None)

        # Conectar al destino que corresponda y hacer de puente
        if destino_v2ray:
            dest = socket.create_connection(("127.0.0.1", destino_v2ray), timeout=10)
        else:
            dest = socket.create_connection((host, port), timeout=10)
        dest.settimeout(None)

        # Lo que ya leimos del cliente se reenvia primero, para no
        # perder ni un byte del handshake.
        if pendiente:
            dest.sendall(pendiente)

        t1 = threading.Thread(target=forward, args=(client, dest), daemon=True)
        t2 = threading.Thread(target=forward, args=(dest, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        print(f"[CTManager WS] Error con cliente: {e}", flush=True)
        for s in (client, dest):
            if s:
                try:
                    s.close()
                except Exception:
                    pass


def start_server(port, cfg):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("0.0.0.0", port))
    except OSError as e:
        print(f"[CTManager WS] No se pudo abrir el puerto {port}: {e}", flush=True)
        return
    srv.listen(512)
    extra = ""
    rutas = cfg.get("rutas") or {}
    if not rutas and cfg.get("vless_path"):
        rutas = {cfg["vless_path"]: cfg.get("vless_port")}
    if rutas:
        detalle = ", ".join(f"{r} -> {p}" for r, p in rutas.items())
        extra = f" | V2Ray: {detalle}"
    if cfg.get("tls_port"):
        extra += f" | TLS -> 127.0.0.1:{cfg['tls_port']}"
    print(f"[CTManager WS] Escuchando en {port} -> "
          f"{cfg.get('target_host')}:{cfg.get('target_port')} "
          f"| Payload HTTP {cfg.get('payload')}{extra}", flush=True)
    while True:
        try:
            client, addr = srv.accept()
            threading.Thread(target=handle_client,
                             args=(client, cfg), daemon=True).start()
        except Exception as e:
            print(f"[CTManager WS] Error aceptando conexion: {e}", flush=True)


def main():
    cfg = load_config()
    ports = []
    if cfg.get("enable_ws", True) and cfg.get("ws_port"):
        ports.append(int(cfg["ws_port"]))
    if cfg.get("enable_wss", True) and cfg.get("wss_port"):
        ports.append(int(cfg["wss_port"]))
    ports = sorted(set(ports))

    if not ports:
        print("[CTManager WS] No hay puertos configurados.", flush=True)
        sys.exit(1)

    hilos = []
    for p in ports:
        t = threading.Thread(target=start_server, args=(p, cfg), daemon=True)
        t.start()
        hilos.append(t)
    for t in hilos:
        t.join()


if __name__ == "__main__":
    main()
