#!/usr/bin/env python3
# CTManager SOCKS Injector - by CHARLY_TRICKS
# Tunel transparente: redirige al SSH/Dropbear sin autenticacion propia
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
        "200": b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
        "101": b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
    }
    payload = payloads.get(payload_code, payloads["200"])
    try:
        data = client_socket.recv(4096)
        if not data:
            client_socket.close()
            return
        client_socket.sendall(payload)
        dest = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        dest.connect((dest_host, dest_port))
        threading.Thread(target=forward, args=(client_socket, dest), daemon=True).start()
        threading.Thread(target=forward, args=(dest, client_socket), daemon=True).start()
    except:
        try: client_socket.close()
        except: pass

def start(listen_port, dest_host, dest_port, payload_code):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', listen_port))
    srv.listen(200)
    print(f"[SOCKS] {listen_port} -> {dest_host}:{dest_port} | {payload_code}")
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle_client, args=(client, dest_host, dest_port, payload_code), daemon=True).start()

if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Uso: proxy.py <puerto> <host_destino> <puerto_destino> <payload>")
        sys.exit(1)
    start(int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4])
