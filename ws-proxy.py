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


def handle_client(client, cfg):
    payload = PAYLOADS.get(str(cfg.get("payload", "101")), PAYLOADS["101"])
    host = cfg.get("target_host", "127.0.0.1")
    port = int(cfg.get("target_port", 22))
    dest = None
    try:
        client.settimeout(15)
        # Leer el request inicial de la app (no nos importa el contenido)
        try:
            client.recv(8192)
        except socket.timeout:
            pass

        # Contestar el payload que la app espera
        client.sendall(payload)

        # Algunas apps mandan un segundo request despues del 101.
        # Lo absorbemos si llega rapido, si no seguimos.
        client.settimeout(1)
        try:
            client.recv(8192)
        except Exception:
            pass
        client.settimeout(None)

        # Conectar al SSH local y hacer de puente
        dest = socket.create_connection((host, port), timeout=10)
        dest.settimeout(None)

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
    print(f"[CTManager WS] Escuchando en {port} -> "
          f"{cfg.get('target_host')}:{cfg.get('target_port')} "
          f"| Payload HTTP {cfg.get('payload')}", flush=True)
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
