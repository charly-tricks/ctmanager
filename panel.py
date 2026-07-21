#!/usr/bin/env python3
# ============================================================
#  CTMANAGER PANEL  -  by CHARLY_TRICKS
#
#  Panel web para gestionar las cuentas SSH.
#  NO tiene base propia: lee la misma que usa ctmanager-cli y
#  ejecuta el CLI para cualquier cambio. Asi nunca se
#  desincronizan.
#
#  Corre en el puerto 8088 por defecto.
# ============================================================

import os
import json
import time
import sqlite3
import secrets
import hashlib
import subprocess
import threading
from typing import Optional

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse
import uvicorn

DB = "/etc/ctmanager/config/ssh_users.db"
CLI = "/usr/local/bin/ctmanager-cli"
PANEL_CFG = "/etc/ctmanager/panel/config.json"
PORT = int(os.environ.get("CTMANAGER_PANEL_PORT", "8088"))

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

# Sesiones en memoria: se pierden al reiniciar, y esta bien.
SESIONES = {}
SESION_HORAS = 12


# ── Autenticacion ────────────────────────────────────────────
def cargar_cfg():
    try:
        with open(PANEL_CFG) as f:
            return json.load(f)
    except Exception:
        return {}


def hash_pass(clave: str, sal: str) -> str:
    return hashlib.sha256((sal + clave).encode()).hexdigest()


def verificar_clave(clave: str) -> bool:
    cfg = cargar_cfg()
    if not cfg.get("hash") or not cfg.get("sal"):
        return False
    return secrets.compare_digest(hash_pass(clave, cfg["sal"]), cfg["hash"])


def sesion_valida(request: Request) -> bool:
    token = request.cookies.get("ctm_sesion")
    if not token or token not in SESIONES:
        return False
    if time.time() - SESIONES[token] > SESION_HORAS * 3600:
        SESIONES.pop(token, None)
        return False
    return True


def exigir_sesion(request: Request):
    if not sesion_valida(request):
        raise HTTPException(status_code=401, detail="Sesión expirada")


# ── Acceso a datos ───────────────────────────────────────────
def cli(*args) -> dict:
    """Ejecuta ctmanager-cli sin shell y devuelve el JSON."""
    try:
        r = subprocess.run([CLI, *args, "--json"],
                           capture_output=True, text=True, timeout=30)
        salida = (r.stdout + r.stderr).strip()
        for linea in reversed([l.strip() for l in salida.split("\n") if l.strip()]):
            if linea.startswith("{") and linea.endswith("}"):
                try:
                    return json.loads(linea)
                except json.JSONDecodeError:
                    continue
        return {"ok": False, "error": salida or "sin respuesta"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "el comando tardó demasiado"}
    except FileNotFoundError:
        return {"ok": False, "error": "no se encuentra ctmanager-cli"}


def conexiones(usuario: str) -> int:
    try:
        r = subprocess.run(["ps", "-u", usuario, "-o", "comm="],
                           capture_output=True, text=True, timeout=5)
        return sum(1 for l in r.stdout.split("\n")
                   if l.strip() in ("sshd", "dropbear"))
    except Exception:
        return 0


def leer_usuarios():
    if not os.path.exists(DB):
        return []
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    try:
        filas = con.execute("""
            SELECT username, password,
                   COALESCE(limite,1)     AS limite,
                   COALESCE(mb_limit,0)   AS mb_limit,
                   COALESCE(bytes_uso,0)  AS bytes_uso,
                   COALESCE(expires_at,'') AS expires_at,
                   activo, created_at
            FROM users ORDER BY id DESC
        """).fetchall()
    except sqlite3.Error:
        return []
    finally:
        con.close()

    ahora = time.time()
    salida = []
    for f in filas:
        dias = None
        if f["expires_at"]:
            try:
                t = time.mktime(time.strptime(f["expires_at"], "%Y-%m-%d %H:%M:%S"))
                dias = max(0, int((t - ahora) // 86400))
            except ValueError:
                dias = None
        limite_bytes = f["mb_limit"] * 1048576
        pct = int(f["bytes_uso"] * 100 / limite_bytes) if limite_bytes else 0
        salida.append({
            "usuario": f["username"],
            "password": f["password"],
            "limite": f["limite"],
            "mb_limit": f["mb_limit"],
            "bytes_uso": f["bytes_uso"],
            "porcentaje": min(pct, 100),
            "dias": dias,
            "activo": f["activo"],
            "conexiones": conexiones(f["username"]),
            "creado": f["created_at"],
        })
    return salida


# Servicios que el panel puede prender, apagar e instalar.
# La clave es el servicio; el valor, el comando del CLI que lo instala.
GESTIONABLES = {
    "ctmanager-ws":      "install-proxy",
    "ctmanager-badvpn":  "install-badvpn",
    "ctmanager-limiter": "install-limiter",
    "ctmanager-acct":    "install-accounting",
}

# Instalaciones en curso: {servicio: "instalando" | "error: ..."}
TAREAS = {}


def servicio_instalado(nombre: str) -> bool:
    return os.path.exists(f"/etc/systemd/system/{nombre}.service")


def estado_sistema():
    servicios = {}
    for s in ("ctmanager-limiter", "ctmanager-acct", "ctmanager-ws",
              "ctmanager-badvpn", "ctmanager-panel"):
        if s in TAREAS:
            servicios[s] = TAREAS[s]
            continue
        if s in GESTIONABLES and not servicio_instalado(s):
            servicios[s] = "no-instalado"
            continue
        try:
            r = subprocess.run(["systemctl", "is-active", s],
                               capture_output=True, text=True, timeout=5)
            servicios[s] = r.stdout.strip()
        except Exception:
            pass
    # ssh y sshd son el mismo servicio segun la distro: mostrar uno solo
    for s in ("ssh", "sshd"):
        try:
            r = subprocess.run(["systemctl", "is-active", s],
                               capture_output=True, text=True, timeout=5)
            if r.stdout.strip() == "active":
                servicios["ssh"] = "active"
                break
        except Exception:
            pass
    servicios.setdefault("ssh", "inactive")

    # BBR no es un servicio: es un ajuste del kernel. Se consulta aparte.
    bbr = {"activo": False, "congestion": "?"}
    try:
        r = subprocess.run(["sysctl", "-n", "net.ipv4.tcp_congestion_control"],
                           capture_output=True, text=True, timeout=5)
        actual = r.stdout.strip()
        bbr = {"activo": actual == "bbr", "congestion": actual or "?"}
    except Exception:
        pass

    puertos = []
    try:
        r = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True, timeout=5)
        vistos = set()
        for linea in r.stdout.split("\n")[1:]:
            partes = linea.split()
            if len(partes) < 4:
                continue
            direccion = partes[3]
            puerto = direccion.rsplit(":", 1)[-1]
            proc = ""
            if "users:((" in linea:
                proc = linea.split('users:(("')[1].split('"')[0]
            clave = (puerto, proc)
            if clave not in vistos and puerto.isdigit():
                vistos.add(clave)
                puertos.append({"puerto": int(puerto), "proceso": proc or "-"})
    except Exception:
        pass
    puertos.sort(key=lambda p: p["puerto"])
    return {"servicios": servicios, "puertos": puertos, "bbr": bbr}


# ── API ──────────────────────────────────────────────────────
@app.post("/api/entrar")
async def entrar(request: Request):
    datos = await request.json()
    if not verificar_clave(datos.get("clave", "")):
        # Freno simple contra prueba y error
        time.sleep(1.5)
        return JSONResponse({"ok": False, "error": "Contraseña incorrecta"},
                            status_code=401)
    token = secrets.token_urlsafe(32)
    SESIONES[token] = time.time()
    resp = JSONResponse({"ok": True})
    resp.set_cookie("ctm_sesion", token, httponly=True, samesite="lax", max_age=SESION_HORAS * 3600)
    return resp


@app.post("/api/salir")
async def salir(request: Request):
    token = request.cookies.get("ctm_sesion")
    SESIONES.pop(token, None)
    resp = JSONResponse({"ok": True})
    resp.delete_cookie("ctm_sesion")
    return resp


_IP_CACHE = {"ip": "", "t": 0}


def ip_publica():
    """Se cachea: no tiene sentido preguntarla en cada refresco."""
    if _IP_CACHE["ip"] and time.time() - _IP_CACHE["t"] < 3600:
        return _IP_CACHE["ip"]
    try:
        r = subprocess.run(["curl", "-s", "--max-time", "6", "ifconfig.me"],
                           capture_output=True, text=True, timeout=10)
        ip = r.stdout.strip()
        if ip:
            _IP_CACHE.update({"ip": ip, "t": time.time()})
        return ip
    except Exception:
        return ""


def leer_v2ray():
    """Cuentas V2Ray. Si no esta instalado, devuelve lista vacia."""
    if not os.path.exists("/etc/ctmanager/xray/config.json"):
        return {"instalado": False, "cuentas": [], "tls": {}}
    r = cli("vless", "list")
    t = cli("tls-estado")
    return {
        "instalado": True,
        "cuentas": r.get("vless", []) if r.get("ok") else [],
        "tls": t if t.get("ok") else {},
        "ip": ip_publica(),
        "instalando_tls": "tls" in TAREAS,
    }


@app.get("/api/datos")
async def datos(request: Request):
    exigir_sesion(request)
    return {"usuarios": leer_usuarios(), "sistema": estado_sistema(),
            "v2ray": leer_v2ray()}


@app.post("/api/v2ray/crear")
async def v2ray_crear(request: Request):
    exigir_sesion(request)
    d = await request.json()
    return cli("vless", "add",
               str(d["usuario"]).lower().strip(),
               str(int(d["dias"])), str(int(d["gb"])),
               str(d.get("protocolo", "vless")))


@app.post("/api/v2ray/accion")
async def v2ray_accion(request: Request):
    exigir_sesion(request)
    d = await request.json()
    u = str(d["usuario"]).lower().strip()
    acc = d.get("accion", "")
    if acc == "link":
        return cli("vless", "link", u)
    if acc == "borrar":
        return cli("vless", "del", u)
    if acc == "instalar":
        def tarea():
            TAREAS["v2ray"] = "instalando"
            try:
                subprocess.run([CLI, "install-v2ray"], capture_output=True, timeout=600)
            except Exception:
                pass
            finally:
                TAREAS.pop("v2ray", None)
        threading.Thread(target=tarea, daemon=True).start()
        return {"ok": True, "msg": "instalando"}
    return {"ok": False, "error": "acción desconocida"}


@app.post("/api/crear")
async def crear(request: Request):
    exigir_sesion(request)
    d = await request.json()
    return cli("add", str(d["usuario"]).lower().strip(), str(d["clave"]),
               str(int(d["dias"])), str(int(d["dispositivos"])), str(int(d["gb"])))


@app.post("/api/accion")
async def accion(request: Request):
    exigir_sesion(request)
    d = await request.json()
    u = str(d["usuario"]).lower().strip()
    acc = d["accion"]
    if acc == "renovar":
        return cli("renew", u, str(int(d["dias"])))
    if acc == "cuota":
        return cli("quota", u, str(int(d["gb"])), "GB")
    if acc == "bloquear":
        return cli("lock", u)
    if acc == "desbloquear":
        return cli("unlock", u)
    if acc == "reset":
        return cli("reset-usage", u)
    if acc == "borrar":
        return cli("del", u)
    return {"ok": False, "error": "acción desconocida"}


# ── Interfaz ─────────────────────────────────────────────────
BANNER_TPL = "/etc/ctmanager/banner.tpl"
BANNER_DEFECTO = (
    '<font color="green">Usuario: USER</font>\n'
    '<font color="blue">Vence: EXP  (DAYS dias)</font>\n'
    '<font color="orange">Consumido: TRF de LIMIT</font>\n'
)


@app.post("/api/servicio")
async def servicio(request: Request):
    exigir_sesion(request)
    d = await request.json()
    nombre = d.get("nombre", "")
    accion = d.get("accion", "")

    # BBR es un ajuste del kernel, no un servicio: se activa y ya.
    if nombre == "bbr":
        if accion != "install":
            return {"ok": False, "error": "BBR solo se activa"}
        return cli("bbr")

    if nombre not in GESTIONABLES:
        return {"ok": False, "error": "servicio no gestionable"}

    if accion in ("start", "stop", "restart"):
        if not servicio_instalado(nombre):
            return {"ok": False, "error": "el servicio no está instalado"}
        try:
            subprocess.run(["systemctl", accion, nombre],
                           capture_output=True, timeout=20)
        except Exception as e:
            return {"ok": False, "error": str(e)}
        return {"ok": True, "msg": "listo"}

    if accion == "install":
        if nombre in TAREAS:
            return {"ok": False, "error": "ya se está instalando"}

        def tarea():
            # BadVPN compila desde fuente: puede tardar varios minutos.
            TAREAS[nombre] = "instalando"
            try:
                r = subprocess.run([CLI, GESTIONABLES[nombre]],
                                   capture_output=True, text=True, timeout=900)
                if r.returncode != 0:
                    TAREAS[nombre] = "error"
                    time.sleep(8)
            except Exception:
                TAREAS[nombre] = "error"
                time.sleep(8)
            finally:
                TAREAS.pop(nombre, None)

        threading.Thread(target=tarea, daemon=True).start()
        return {"ok": True, "msg": "instalando en segundo plano"}

    return {"ok": False, "error": "acción desconocida"}


@app.post("/api/tls")
async def activar_tls(request: Request):
    exigir_sesion(request)
    d = await request.json()
    dominio = str(d.get("dominio", "")).strip().lower()
    correo = str(d.get("correo", "")).strip()

    if not dominio or "." not in dominio or " " in dominio:
        return {"ok": False, "error": "Escribí un dominio válido"}
    if "tls" in TAREAS:
        return {"ok": False, "error": "ya se está activando"}

    def tarea():
        TAREAS["tls"] = "instalando"
        try:
            args = [CLI, "install-tls", dominio]
            if correo:
                args.append(correo)
            subprocess.run(args, capture_output=True, timeout=300)
        except Exception:
            pass
        finally:
            TAREAS.pop("tls", None)

    threading.Thread(target=tarea, daemon=True).start()
    return {"ok": True, "msg": "activando"}


@app.get("/api/banner")
async def ver_banner(request: Request):
    exigir_sesion(request)
    try:
        with open(BANNER_TPL) as f:
            return {"ok": True, "texto": f.read()}
    except FileNotFoundError:
        return {"ok": True, "texto": BANNER_DEFECTO}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/banner")
async def guardar_banner(request: Request):
    exigir_sesion(request)
    d = await request.json()
    texto = str(d.get("texto", ""))
    if len(texto) > 4000:
        return {"ok": False, "error": "El banner es demasiado largo (máximo 4000 caracteres)"}
    try:
        os.makedirs(os.path.dirname(BANNER_TPL), exist_ok=True)
        with open(BANNER_TPL, "w") as f:
            f.write(texto)
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return cli("banner-sync")


@app.get("/", response_class=HTMLResponse)
async def raiz(request: Request):
    return HTMLResponse(PAGINA)


PAGINA = r"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>CTManager</title>
<style>
  :root{
    --ink:#0D1017; --panel:#151A24; --raise:#1D2431; --line:#28313F;
    --text:#E8ECF3; --dim:#7E8899;
    --signal:#F2A63B; --alive:#48D0A0; --dead:#E15A5E;
    --nota:#5FC8DE;
    --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace;
    --sans:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--ink);color:var(--text);font-family:var(--sans);
       font-size:15px;line-height:1.45;padding-bottom:80px;
       -webkit-font-smoothing:antialiased}

  header{position:sticky;top:0;z-index:20;background:rgba(13,16,23,.94);
         backdrop-filter:blur(8px);border-bottom:1px solid var(--line);
         padding:14px 16px;display:flex;align-items:baseline;gap:10px}
  header h1{font-family:var(--mono);font-size:15px;font-weight:600;
            letter-spacing:.14em;text-transform:uppercase}
  header .tag{font-family:var(--mono);font-size:11px;color:var(--signal);
              letter-spacing:.1em}
  header button{margin-left:auto;background:none;border:1px solid var(--line);
                color:var(--dim);font-size:12px;padding:5px 10px;border-radius:6px;
                cursor:pointer;font-family:var(--mono)}

  main{padding:16px;max-width:760px;margin:0 auto}

  /* resumen */
  .cifras{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:18px}
  .cifra{background:var(--panel);border:1px solid var(--line);border-radius:10px;
         padding:12px 10px}
  .cifra b{display:block;font-family:var(--mono);font-size:22px;line-height:1.1}
  .cifra span{font-size:11px;color:var(--dim);letter-spacing:.06em;
              text-transform:uppercase}

  h2{font-family:var(--mono);font-size:11px;letter-spacing:.16em;
     text-transform:uppercase;color:var(--dim);margin:22px 0 10px;
     display:flex;align-items:center;gap:10px}
  h2::after{content:'';flex:1;height:1px;background:var(--line)}

  /* tarjeta de usuario */
  .cuenta{background:var(--panel);border:1px solid var(--line);border-radius:12px;
          padding:14px;margin-bottom:10px}
  .cuenta.off{opacity:.55}
  .fila1{display:flex;align-items:center;gap:10px;margin-bottom:4px}
  .nombre{font-family:var(--mono);font-size:15px;font-weight:600;
          word-break:break-all;flex:1}
  .punto{width:8px;height:8px;border-radius:50%;flex:none}
  .punto.on{background:var(--alive);box-shadow:0 0 8px var(--alive)}
  .punto.no{background:var(--dead)}
  .clave{font-family:var(--mono);font-size:12px;color:var(--dim);
         margin-bottom:12px;word-break:break-all}

  /* SEÑA: medidor segmentado, como barras de señal */
  .medidor{display:flex;gap:2px;height:8px;margin-bottom:6px}
  .seg{flex:1;background:var(--raise);border-radius:1px}
  .seg.lleno{background:var(--signal)}
  .seg.alto{background:var(--dead)}
  .consumo{display:flex;justify-content:space-between;font-family:var(--mono);
           font-size:11px;color:var(--dim);margin-bottom:12px}
  .consumo .gasto{color:var(--text)}

  .datos{display:flex;gap:14px;font-family:var(--mono);font-size:12px;
         color:var(--dim);margin-bottom:12px;flex-wrap:wrap}
  .datos b{color:var(--text);font-weight:600}

  .botones{display:flex;gap:6px;flex-wrap:wrap}
  .botones button{flex:1;min-width:70px;background:var(--raise);
                  border:1px solid var(--line);color:var(--text);
                  font-size:12px;padding:8px 6px;border-radius:7px;cursor:pointer;
                  font-family:var(--sans)}
  .botones button:active{background:var(--line)}
  .botones button.peligro{color:var(--dead)}

  /* formulario */
  .caja{background:var(--panel);border:1px solid var(--line);
        border-radius:12px;padding:14px;margin-bottom:10px}
  label{display:block;font-size:11px;color:var(--dim);letter-spacing:.06em;
        text-transform:uppercase;margin-bottom:5px}
  input{width:100%;background:var(--ink);border:1px solid var(--line);
        color:var(--text);padding:11px;border-radius:8px;font-size:15px;
        font-family:var(--mono);margin-bottom:12px}
  input:focus{outline:2px solid var(--signal);outline-offset:-1px}
  .duo{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  .principal{width:100%;background:var(--signal);color:#0D1017;border:none;
             padding:13px;border-radius:8px;font-size:15px;font-weight:600;
             cursor:pointer;font-family:var(--sans)}

  /* estado del sistema */
  .linea{display:flex;justify-content:space-between;align-items:center;
         padding:11px 0;border-bottom:1px solid var(--line);
         font-family:var(--mono);font-size:12px;gap:10px}
  .linea .acc{display:flex;align-items:center;gap:9px;flex:none}
  .mini{background:var(--raise);border:1px solid var(--line);color:var(--signal);
        font-size:11px;padding:5px 10px;border-radius:6px;cursor:pointer;
        font-family:var(--sans)}
  .mini:disabled{opacity:.5;cursor:default}
  .sw{width:38px;height:21px;background:var(--ink);border:1px solid var(--line);
      border-radius:11px;position:relative;flex:none;cursor:pointer}
  .sw.on{background:var(--alive);border-color:var(--alive)}
  .sw i{position:absolute;top:2px;left:2px;width:15px;height:15px;border-radius:50%;
        background:var(--dim);transition:transform .15s,background .15s}
  .sw.on i{transform:translateX(17px);background:#0D1017}
  .cargando{color:var(--signal)}
  .linea .rot{display:flex;flex-direction:column;gap:2px;min-width:0}
  .linea .nota{font-family:var(--sans);font-size:11px;color:var(--nota);
               line-height:1.35;opacity:.85}
  .linea:last-child{border:none}
  .linea span:first-child{color:var(--dim)}
  .ok{color:var(--alive)} .mal{color:var(--dead)}

  .vacio{text-align:center;color:var(--dim);padding:32px 16px;font-size:14px}

  .opciones{display:flex;gap:6px;margin-bottom:8px}
  .op{flex:1;background:var(--ink);border:1px solid var(--line);color:var(--dim);
      font-size:12px;padding:10px 4px;border-radius:8px;cursor:pointer;
      font-family:var(--sans)}
  .op.elegida{border-color:var(--signal);color:var(--signal);background:var(--raise)}
  .op:disabled{opacity:.4;cursor:default}

  .enlace{background:var(--ink);border:1px solid var(--line);border-radius:8px;
          padding:10px;font-family:var(--mono);font-size:11px;word-break:break-all;
          color:var(--nota);margin-bottom:10px;line-height:1.5}
  .etiqueta{display:inline-block;font-family:var(--mono);font-size:10px;
            letter-spacing:.08em;padding:3px 7px;border-radius:5px;
            border:1px solid var(--line);color:var(--dim)}
  .etiqueta.tls{color:var(--alive);border-color:var(--alive)}

  .info{border-left:2px solid var(--nota);padding-left:12px;margin-bottom:14px}
  .info h4{font-size:13px;font-weight:600;margin-bottom:6px;color:var(--text)}
  .info p, .info li{font-size:12px;color:var(--nota);line-height:1.55;opacity:.9}
  .info ol{margin:6px 0 0 16px}
  .info li{margin-bottom:4px}
  .info code{font-family:var(--mono);background:var(--ink);padding:1px 5px;
             border-radius:4px;font-size:11px;color:var(--text)}
  .aviso-clave{color:var(--signal);font-size:12px;margin-top:8px;line-height:1.5}

  /* interruptor de modo */
  .palanca{display:flex;align-items:center;gap:10px;cursor:pointer;
           margin-bottom:14px;user-select:none}
  .riel{width:42px;height:24px;background:var(--ink);border:1px solid var(--line);
        border-radius:12px;position:relative;flex:none;transition:background .15s}
  .riel.on{background:var(--signal);border-color:var(--signal)}
  .perilla{width:18px;height:18px;background:var(--dim);border-radius:50%;
           position:absolute;top:2px;left:2px;transition:transform .15s,background .15s}
  .riel.on .perilla{transform:translateX(18px);background:#0D1017}
  .palanca span{font-size:13px;color:var(--dim)}

  .ayuda{font-size:12px;color:var(--dim);margin-bottom:12px;line-height:1.4}

  /* editor de banner */
  .fichas{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px}
  .fichas button{background:var(--raise);border:1px solid var(--line);
                 color:var(--signal);font-family:var(--mono);font-size:11px;
                 padding:5px 9px;border-radius:6px;cursor:pointer;letter-spacing:.05em}
  textarea{width:100%;background:var(--ink);border:1px solid var(--line);
           color:var(--text);padding:11px;border-radius:8px;font-size:13px;
           font-family:var(--mono);margin-bottom:12px;resize:vertical;line-height:1.5}
  textarea:focus{outline:2px solid var(--signal);outline-offset:-1px}
  .previa{background:#000;border:1px solid var(--line);border-radius:8px;
          padding:12px;font-family:var(--mono);font-size:13px;line-height:1.6;
          margin-bottom:12px;min-height:60px;word-break:break-word}

  /* entrar */
  #entrar{max-width:320px;margin:18vh auto;padding:0 16px}
  #entrar h1{font-family:var(--mono);font-size:18px;letter-spacing:.16em;
             text-align:center;margin-bottom:6px}
  #entrar p{text-align:center;color:var(--dim);font-size:13px;margin-bottom:22px}

  #aviso{position:fixed;left:16px;right:16px;bottom:16px;z-index:50;
         background:var(--raise);border:1px solid var(--line);border-left:3px solid var(--signal);
         padding:13px 15px;border-radius:9px;font-size:13px;display:none;
         max-width:520px;margin:0 auto}
  @media(prefers-reduced-motion:no-preference){
    #aviso{transition:opacity .2s}
  }
</style>
</head>
<body>

<div id="entrar">
  <h1>CTMANAGER</h1>
  <p>Panel de cuentas</p>
  <input type="password" id="clave" placeholder="Contraseña" autocomplete="current-password">
  <button class="principal" onclick="entrar()">Entrar</button>
</div>

<div id="app" style="display:none">
  <header>
    <h1>CTManager</h1>
    <span class="tag" id="reloj"></span>
    <button onclick="salir()">Salir</button>
  </header>
  <main>
    <div class="cifras">
      <div class="cifra"><b id="cTotal">0</b><span>Cuentas</span></div>
      <div class="cifra"><b id="cOnline">0</b><span>Conectados</span></div>
      <div class="cifra"><b id="cVencen">0</b><span>Vencen ≤3d</span></div>
    </div>

    <h2>Cuentas</h2>
    <div id="lista"></div>

    <h2>Crear cuenta</h2>
    <div class="caja">
      <div class="palanca" onclick="cambiarModo()">
        <div class="riel" id="riel"><div class="perilla"></div></div>
        <span id="modoTexto">Usuario y contraseña</span>
      </div>

      <div id="campoNormal">
        <label>Usuario</label>
        <input id="nUsuario" placeholder="juan" autocapitalize="off">
        <label>Contraseña</label>
        <input id="nClave" placeholder="dejar vacío para generar una">
      </div>

      <div id="campoHwid" style="display:none">
        <label>HWID del dispositivo</label>
        <input id="nHwid" placeholder="32 caracteres" autocapitalize="off">
        <p class="ayuda" id="pistaHwid">Se copia desde la app del cliente.</p>
      </div>

      <div class="duo">
        <div><label>Días</label><input id="nDias" type="number" value="30" inputmode="numeric"></div>
        <div><label>Dispositivos</label><input id="nDisp" type="number" value="1" inputmode="numeric"></div>
      </div>
      <label>Datos en GB (0 = sin límite)</label>
      <input id="nGb" type="number" value="0" inputmode="numeric">
      <button class="principal" onclick="crear()">Crear cuenta</button>
    </div>

    <h2>Cuentas V2Ray</h2>
    <div id="v2rayLista"></div>
    <div class="caja" id="tlsCaja" style="display:none"></div>

    <div class="caja" id="v2rayForm" style="display:none">
      <label>Protocolo</label>
      <div class="opciones" id="protoOpciones">
        <button class="op elegida" data-p="vless"     onclick="elegirProto(this)">VLESS</button>
        <button class="op"          data-p="vmess"    onclick="elegirProto(this)">VMess</button>
        <button class="op"          data-p="vless-tls" onclick="elegirProto(this)">VLESS + TLS</button>
      </div>
      <p class="ayuda" id="protoAyuda">Sin cifrar, por el puerto 80.</p>

      <label>Nombre de la cuenta</label>
      <input id="vUsuario" placeholder="cliente1" autocapitalize="off">
      <div class="duo">
        <div><label>Días</label><input id="vDias" type="number" value="30" inputmode="numeric"></div>
        <div><label>Datos en GB</label><input id="vGb" type="number" value="0" inputmode="numeric"></div>
      </div>
      <button class="principal" onclick="crearV2ray()">Crear cuenta V2Ray</button>
    </div>

    <h2>Mensaje al conectar</h2>
    <div class="caja">
      <p class="ayuda">Esto ve el cliente en su app al conectarse.
         Tocá una etiqueta para insertarla.</p>
      <div class="fichas">
        <button onclick="insertar('USER')">USER</button>
        <button onclick="insertar('EXP')">EXP</button>
        <button onclick="insertar('DAYS')">DAYS</button>
        <button onclick="insertar('TRF')">TRF</button>
        <button onclick="insertar('LIMIT')">LIMIT</button>
      </div>
      <textarea id="bTexto" rows="5" spellcheck="false"
                oninput="verPrevia()"></textarea>
      <label>Así lo va a ver</label>
      <div class="previa" id="bPrevia"></div>
      <button class="principal" onclick="guardarBanner()">Guardar mensaje</button>
    </div>

    <h2>Servidor</h2>
    <div class="caja" id="sistema"></div>
  </main>
</div>

<div id="aviso"></div>

<script>
let temporizador = null;

function avisar(texto, malo){
  const a = document.getElementById('aviso');
  a.textContent = texto;
  a.style.borderLeftColor = malo ? 'var(--dead)' : 'var(--alive)';
  a.style.display = 'block';
  clearTimeout(temporizador);
  temporizador = setTimeout(()=> a.style.display='none', 3200);
}

async function pedir(url, cuerpo){
  const opciones = cuerpo
    ? {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(cuerpo)}
    : {};
  const r = await fetch(url, opciones);
  if(r.status === 401){ mostrarEntrar(); throw new Error('sesion'); }
  return r.json();
}

function mostrarEntrar(){
  document.getElementById('entrar').style.display='block';
  document.getElementById('app').style.display='none';
}

async function entrar(){
  const clave = document.getElementById('clave').value;
  const r = await fetch('/api/entrar', {method:'POST',
    headers:{'Content-Type':'application/json'}, body:JSON.stringify({clave})});
  const d = await r.json();
  if(d.ok){
    document.getElementById('entrar').style.display='none';
    document.getElementById('app').style.display='block';
    cargar(); cargarBanner();
  } else {
    avisar(d.error || 'No se pudo entrar', true);
  }
}

async function salir(){
  await fetch('/api/salir', {method:'POST'});
  location.reload();
}

function tamano(b){
  if(b >= 1073741824) return (b/1073741824).toFixed(2)+' GB';
  if(b >= 1048576)    return (b/1048576).toFixed(1)+' MB';
  if(b >= 1024)       return (b/1024).toFixed(0)+' KB';
  return b+' B';
}

function medidor(pct, sinLimite){
  let h = '<div class="medidor">';
  for(let i=0;i<20;i++){
    const activo = !sinLimite && pct > i*5;
    const clase = activo ? (pct >= 85 ? 'seg lleno alto' : 'seg lleno') : 'seg';
    h += '<div class="'+clase+'"></div>';
  }
  return h + '</div>';
}

async function cargar(){
  let d;
  try { d = await pedir('/api/datos'); } catch(e){ return; }

  const us = d.usuarios || [];
  document.getElementById('cTotal').textContent = us.length;
  document.getElementById('cOnline').textContent =
    us.reduce((s,u)=> s + u.conexiones, 0);
  document.getElementById('cVencen').textContent =
    us.filter(u => u.dias !== null && u.dias <= 3 && u.activo).length;

  const lista = document.getElementById('lista');
  if(!us.length){
    lista.innerHTML = '<div class="vacio">Todavía no hay cuentas.<br>Creá la primera abajo.</div>';
  } else {
    lista.innerHTML = us.map(u => {
      const sinLimite = u.mb_limit === 0;
      const cuota = sinLimite ? 'sin límite' : (u.mb_limit/1024).toFixed(0)+' GB';
      const dias = u.dias === null ? '∞' : u.dias;
      return `
      <div class="cuenta ${u.activo ? '' : 'off'}">
        <div class="fila1">
          <div class="punto ${u.activo ? 'on' : 'no'}"></div>
          <div class="nombre">${u.usuario}</div>
        </div>
        <div class="clave">${u.password}</div>
        ${medidor(u.porcentaje, sinLimite)}
        <div class="consumo">
          <span class="gasto">${tamano(u.bytes_uso)}</span>
          <span>${cuota}</span>
        </div>
        <div class="datos">
          <span>vence en <b>${dias}</b> días</span>
          <span>conectados <b>${u.conexiones}/${u.limite}</b></span>
        </div>
        <div class="botones">
          <button onclick="accion('${u.usuario}','renovar')">Renovar</button>
          <button onclick="accion('${u.usuario}','cuota')">Datos</button>
          <button onclick="accion('${u.usuario}','reset')">Resetear</button>
          <button onclick="accion('${u.usuario}','${u.activo ? 'bloquear' : 'desbloquear'}')">${u.activo ? 'Bloquear' : 'Activar'}</button>
          <button class="peligro" onclick="accion('${u.usuario}','borrar')">Borrar</button>
        </div>
      </div>`;
    }).join('');
  }

  pintarV2ray(d.v2ray);

  const s = d.sistema || {servicios:{}, puertos:[]};
  let html = '';
  const nombres = {
    'ctmanager-limiter':'Límite de dispositivos',
    'ctmanager-acct':'Contador de datos',
    'ctmanager-ws':'Proxy WebSocket',
    'ctmanager-badvpn':'Soporte UDP (BadVPN)',
    'ctmanager-panel':'Panel web',
    'ssh':'Servidor SSH'
  };

  const notas = {
    'ctmanager-limiter':'Cuenta cuántos dispositivos usa cada cliente y cierra los que sobran del plan.',
    'ctmanager-acct':'Mide los datos que consume cada cuenta y la bloquea sola cuando se termina el plan.',
    'ctmanager-ws':'Recibe las conexiones en los puertos 80 y 443 y las lleva al SSH. Es lo que permite conectar donde el 22 está bloqueado.',
    'ctmanager-badvpn':'Habilita el tráfico UDP: sin esto no funcionan las videollamadas, los juegos ni los audios.',
    'ctmanager-panel':'Esta misma pantalla.',
    'ssh':'El servidor al que se conectan los clientes.'
  };
  const gestionables = ['ctmanager-ws','ctmanager-badvpn',
                       'ctmanager-limiter','ctmanager-acct'];
  for(const [k,v] of Object.entries(s.servicios)){
    const vivo = v === 'active';
    let acc = '';

    if(v === 'instalando'){
      acc = '<span class="cargando">instalando…</span>';
    } else if(v === 'error'){
      acc = `<span class="mal">falló</span>
             <button class="mini" onclick="servicio('${k}','install')">Reintentar</button>`;
    } else if(v === 'no-instalado'){
      acc = `<span style="color:var(--dim)">no instalado</span>
             <button class="mini" onclick="servicio('${k}','install')">Instalar</button>`;
    } else if(gestionables.includes(k)){
      acc = `<span class="${vivo?'ok':'mal'}">${vivo?'activo':'detenido'}</span>
             <div class="sw ${vivo?'on':''}"
                  onclick="servicio('${k}','${vivo?'stop':'start'}')"><i></i></div>`;
    } else {
      acc = `<span class="${vivo?'ok':'mal'}">${vivo?'activo':v}</span>`;
    }

    const nota = notas[k] ? `<span class="nota">${notas[k]}</span>` : '';
    html += `<div class="linea">
               <span class="rot"><span>${nombres[k]||k}</span>${nota}</span>
               <span class="acc">${acc}</span>
             </div>`;
  }
  if(s.bbr){
    const on = s.bbr.activo;
    const acc = on
      ? '<span class="ok">activo</span>'
      : `<span class="mal">${s.bbr.congestion}</span>
         <button class="mini" onclick="servicio('bbr','install')">Activar</button>`;
    html += `<div class="linea">
               <span class="rot">
                 <span>Aceleración BBR</span>
                 <span class="nota">Mejora la velocidad cuando la conexión
                 del cliente pierde paquetes, como pasa con datos móviles
                 o señal débil.</span>
               </span>
               <span class="acc">${acc}</span>
             </div>`;
  }

  if(s.puertos.length){
    html += `<div class="linea"><span>Puertos abiertos</span><span>${
      s.puertos.map(p=>p.puerto).join(' · ')}</span></div>`;
  }
  document.getElementById('sistema').innerHTML = html;

  document.getElementById('reloj').textContent =
    new Date().toLocaleTimeString('es-AR',{hour:'2-digit',minute:'2-digit'});
}

let modoHwid = false;

function cambiarModo(){
  modoHwid = !modoHwid;
  document.getElementById('riel').classList.toggle('on', modoHwid);
  document.getElementById('modoTexto').textContent =
    modoHwid ? 'Cuenta por HWID' : 'Usuario y contraseña';
  document.getElementById('campoNormal').style.display = modoHwid ? 'none' : 'block';
  document.getElementById('campoHwid').style.display  = modoHwid ? 'block' : 'none';
}

async function crear(){
  let usuario, clave;

  if(modoHwid){
    const hwid = document.getElementById('nHwid').value.trim().toLowerCase();
    if(!/^[a-f0-9]{32}$/.test(hwid)){
      avisar('El HWID tiene que ser de 32 caracteres (0-9, a-f)', true);
      return;
    }
    usuario = hwid; clave = hwid;
  } else {
    usuario = document.getElementById('nUsuario').value.trim().toLowerCase();
    if(!usuario){ avisar('Escribí un nombre de usuario', true); return; }
    clave = document.getElementById('nClave').value.trim();
    if(!clave){
      const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
      clave = Array.from({length:10}, ()=> abc[Math.floor(Math.random()*abc.length)]).join('');
    }
  }

  const d = await pedir('/api/crear', {
    usuario, clave,
    dias: +document.getElementById('nDias').value || 30,
    dispositivos: +document.getElementById('nDisp').value || 1,
    gb: +document.getElementById('nGb').value || 0
  });
  if(d.ok){
    avisar(modoHwid ? 'Cuenta HWID creada' : ('Cuenta creada: ' + usuario + ' / ' + clave));
    document.getElementById('nUsuario').value = '';
    document.getElementById('nClave').value = '';
    document.getElementById('nHwid').value = '';
    cargar();
  } else {
    avisar(d.error || 'No se pudo crear', true);
  }
}

async function servicio(nombre, accion){
  if(nombre === 'bbr'){
    const d = await pedir('/api/servicio', {nombre, accion:'install'});
    avisar(d.ok ? 'BBR activado' : (d.error || 'No se pudo activar'), !d.ok);
    cargar();
    return;
  }
  if(accion === 'stop' && !confirm('Se detiene el servicio y los clientes conectados por ahí se van a cortar. ¿Seguir?')) return;

  if(accion === 'install' && nombre === 'ctmanager-badvpn'){
    avisar('BadVPN se compila desde el código: puede tardar unos minutos.');
  }

  const d = await pedir('/api/servicio', {nombre, accion});
  if(!d.ok){ avisar(d.error || 'No se pudo', true); return; }
  if(accion === 'install') avisar('Instalando… el estado se actualiza solo.');
  cargar();

  // Refresco mas seguido mientras dura la instalacion
  if(accion === 'install'){
    let n = 0;
    const t = setInterval(()=>{ cargar(); if(++n > 60) clearInterval(t); }, 5000);
  }
}

/* ── Cuentas V2Ray ──────────────────────────────────── */
let protoElegido = 'vless';
let hayTls = false;

function elegirProto(btn){
  if(btn.disabled) return;
  document.querySelectorAll('#protoOpciones .op')
          .forEach(b => b.classList.remove('elegida'));
  btn.classList.add('elegida');
  protoElegido = btn.dataset.p;
  const textos = {
    'vless':     'Sin cifrar, por el puerto 80.',
    'vmess':     'Sin cifrar, por el puerto 80. Otra forma de identificar al usuario.',
    'vless-tls': 'Cifrado con tu certificado, por el puerto 443.'
  };
  document.getElementById('protoAyuda').textContent = textos[protoElegido];
}

function pintarV2ray(v){
  const cont = document.getElementById('v2rayLista');
  const form = document.getElementById('v2rayForm');
  pintarTls(v);

  if(!v || !v.instalado){
    form.style.display = 'none';
    const estado = (typeof TAREAS_V2 !== 'undefined' && TAREAS_V2) ? '' : '';
    cont.innerHTML = `<div class="caja">
        <p class="ayuda">V2Ray permite vender cuentas VLESS y VMess
        además de las SSH, usando el mismo puerto 80.</p>
        <button class="principal" onclick="instalarV2ray()">Instalar V2Ray</button>
      </div>`;
    return;
  }

  form.style.display = 'block';
  hayTls = !!(v.tls && v.tls.tls);
  const btnTls = document.querySelector('#protoOpciones .op[data-p="vless-tls"]');
  if(btnTls){
    btnTls.disabled = !hayTls;
    btnTls.title = hayTls ? '' : 'Falta configurar TLS';
  }

  if(!v.cuentas.length){
    cont.innerHTML = '<div class="vacio">Todavía no hay cuentas V2Ray.</div>';
    return;
  }

  cont.innerHTML = v.cuentas.map(c => {
    const cuota = c.cuota_mb ? (c.cuota_mb/1024).toFixed(0)+' GB' : 'sin límite';
    const vence = (c.expira || '').split(' ')[0] || '∞';
    const esTls = c.protocolo === 'vless-tls';
    return `
    <div class="cuenta ${c.activo ? '' : 'off'}">
      <div class="fila1">
        <div class="punto ${c.activo ? 'on' : 'no'}"></div>
        <div class="nombre">${c.usuario}</div>
        <span class="etiqueta ${esTls ? 'tls' : ''}">${(c.protocolo||'vless').toUpperCase()}</span>
      </div>
      <div class="consumo">
        <span class="gasto">${tamano(c.bytes || 0)}</span>
        <span>${cuota} · vence ${vence}</span>
      </div>
      <div id="link-${c.usuario}"></div>
      <div class="botones">
        <button onclick="verEnlace('${c.usuario}')">Ver enlace</button>
        <button class="peligro" onclick="borrarV2ray('${c.usuario}')">Borrar</button>
      </div>
    </div>`;
  }).join('');
}

function pintarTls(v){
  const caja = document.getElementById('tlsCaja');
  if(!v || !v.instalado){ caja.style.display='none'; return; }
  caja.style.display = 'block';

  if(v.instalando_tls){
    caja.innerHTML = `<div class="info"><h4>Activando conexión segura…</h4>
      <p>Se está pidiendo el certificado. Puede tardar hasta un minuto
      y el servicio se corta unos segundos.</p></div>`;
    return;
  }

  if(v.tls && v.tls.tls){
    caja.innerHTML = `<div class="info">
        <h4>Conexión segura activa</h4>
        <p>Dominio: <code>${v.tls.dominio}</code><br>
        El certificado vence el ${v.tls.vence || 'desconocido'} y se
        renueva solo.</p>
      </div>
      <p class="ayuda">Ya podés crear cuentas con la opción
      <strong>VLESS + TLS</strong>.</p>`;
    return;
  }

  caja.innerHTML = `
    <div class="info">
      <h4>Conexión segura (TLS)</h4>
      <p>Sin esto, las cuentas V2Ray viajan sin cifrar por el puerto 80.
      Con TLS el tráfico va cifrado por el 443 y es mucho más difícil de
      bloquear. Necesitás un dominio propio apuntando a este servidor.</p>
      <h4 style="margin-top:12px">Cómo apuntar tu dominio</h4>
      <ol>
        <li>Entrá a Cloudflare y elegí tu dominio.</li>
        <li>Andá a <strong>DNS → Agregar registro</strong>.</li>
        <li>Tipo <code>A</code>, nombre el subdominio que quieras
            (por ejemplo <code>vpn</code>).</li>
        <li>En contenido poné la IP de este servidor:
            <code>${v.ip || 'la IP de tu VPS'}</code></li>
        <li>Guardá y esperá un par de minutos.</li>
      </ol>
      <p class="aviso-clave">Importante: la nube al lado del registro
      tiene que quedar <strong>gris</strong> (solo DNS). Si la dejás
      naranja, Cloudflare intercepta el tráfico y las conexiones no
      funcionan.</p>
    </div>
    <label>Tu dominio</label>
    <input id="tlsDominio" placeholder="vpn.tudominio.com" autocapitalize="off">
    <label>Correo (opcional, para avisos del certificado)</label>
    <input id="tlsCorreo" placeholder="tucorreo@ejemplo.com" autocapitalize="off">
    <button class="principal" onclick="activarTls()">Activar conexión segura</button>`;
}

async function activarTls(){
  const dominio = (document.getElementById('tlsDominio').value || '').trim().toLowerCase();
  const correo  = (document.getElementById('tlsCorreo').value || '').trim();
  if(!dominio){ avisar('Escribí tu dominio', true); return; }
  if(!confirm('El servicio se va a cortar unos segundos mientras se pide el certificado. ¿Seguir?')) return;

  const d = await pedir('/api/tls', {dominio, correo});
  if(!d.ok){ avisar(d.error || 'No se pudo', true); return; }
  avisar('Pidiendo el certificado…');
  cargar();
  let n = 0;
  const t = setInterval(()=>{ cargar(); if(++n > 24) clearInterval(t); }, 5000);
}

async function instalarV2ray(){
  avisar('Instalando V2Ray, puede tardar un minuto.');
  await pedir('/api/v2ray/accion', {usuario:'-', accion:'instalar'});
  let n = 0;
  const t = setInterval(()=>{ cargar(); if(++n > 24) clearInterval(t); }, 5000);
}

async function crearV2ray(){
  const usuario = document.getElementById('vUsuario').value.trim().toLowerCase();
  if(!usuario){ avisar('Escribí un nombre para la cuenta', true); return; }
  const d = await pedir('/api/v2ray/crear', {
    usuario, protocolo: protoElegido,
    dias: +document.getElementById('vDias').value || 30,
    gb:   +document.getElementById('vGb').value || 0
  });
  if(d.ok){
    avisar('Cuenta V2Ray creada');
    document.getElementById('vUsuario').value = '';
    cargar();
    setTimeout(()=> verEnlace(usuario), 700);
  } else {
    avisar(d.error || 'No se pudo crear', true);
  }
}

async function verEnlace(usuario){
  const caja = document.getElementById('link-' + usuario);
  if(!caja) return;
  if(caja.innerHTML){ caja.innerHTML = ''; return; }
  const d = await pedir('/api/v2ray/accion', {usuario, accion:'link'});
  if(!d.ok){ avisar(d.error || 'No se pudo obtener el enlace', true); return; }
  caja.innerHTML = `<div class="enlace">${d.link}</div>
    <div class="botones" style="margin-bottom:10px">
      <button onclick="copiar('${encodeURIComponent(d.link)}')">Copiar enlace</button>
    </div>`;
}

async function copiar(texto){
  const t = decodeURIComponent(texto);
  try{
    await navigator.clipboard.writeText(t);
    avisar('Enlace copiado');
  }catch(e){
    // En http sin cifrar el portapapeles puede estar bloqueado
    const ta = document.createElement('textarea');
    ta.value = t; document.body.appendChild(ta); ta.select();
    try{ document.execCommand('copy'); avisar('Enlace copiado'); }
    catch(_){ avisar('Copialo a mano desde el recuadro', true); }
    document.body.removeChild(ta);
  }
}

async function borrarV2ray(usuario){
  if(!confirm('Se borra la cuenta ' + usuario + '. ¿Seguir?')) return;
  const d = await pedir('/api/v2ray/accion', {usuario, accion:'borrar'});
  avisar(d.ok ? 'Cuenta borrada' : (d.error || 'Falló'), !d.ok);
  cargar();
}

/* ── Editor del mensaje al conectar ─────────────────── */
function insertar(etiqueta){
  const t = document.getElementById('bTexto');
  const i = t.selectionStart;
  t.value = t.value.slice(0, i) + etiqueta + t.value.slice(t.selectionEnd);
  t.focus();
  t.selectionStart = t.selectionEnd = i + etiqueta.length;
  verPrevia();
}

function verPrevia(){
  const ejemplo = {
    USER: 'juan', EXP: '2026-08-19', DAYS: '29',
    TRF: '3.40 GB', LIMIT: '10.00 GB'
  };
  let html = document.getElementById('bTexto').value;
  html = html.replace(/<\s*(script|iframe|img|svg|style)/gi, '&lt;$1');
  for(const [k,v] of Object.entries(ejemplo)){
    html = html.split(k).join(v);
  }
  document.getElementById('bPrevia').innerHTML = html.replace(/\n/g, '<br>');
}

async function cargarBanner(){
  try{
    const d = await pedir('/api/banner');
    if(d.ok){
      document.getElementById('bTexto').value = d.texto;
      verPrevia();
    }
  }catch(e){}
}

async function guardarBanner(){
  const texto = document.getElementById('bTexto').value;
  const d = await pedir('/api/banner', {texto});
  avisar(d.ok ? 'Mensaje guardado y aplicado a todas las cuentas'
              : (d.error || 'No se pudo guardar'), !d.ok);
}

async function accion(usuario, acc){
  const cuerpo = {usuario, accion: acc};

  if(acc === 'renovar'){
    const n = prompt('¿Cuántos días le sumo a ' + usuario + '?', '30');
    if(!n) return;
    cuerpo.dias = parseInt(n);
  }
  if(acc === 'cuota'){
    const n = prompt('Datos en GB para ' + usuario + ' (0 = sin límite)', '10');
    if(n === null) return;
    cuerpo.gb = parseInt(n);
  }
  if(acc === 'borrar' && !confirm('Se borra la cuenta ' + usuario + ' y se corta su conexión. ¿Seguir?')) return;
  if(acc === 'reset' && !confirm('El consumo de ' + usuario + ' vuelve a cero. ¿Seguir?')) return;

  const d = await pedir('/api/accion', cuerpo);
  avisar(d.ok ? (d.msg || 'Listo') : (d.error || 'Falló'), !d.ok);
  cargar();
}

document.getElementById('clave').addEventListener('keydown', e => {
  if(e.key === 'Enter') entrar();
});

fetch('/api/datos').then(r => {
  if(r.ok){
    document.getElementById('entrar').style.display='none';
    document.getElementById('app').style.display='block';
    cargar(); cargarBanner();
  }
});

setInterval(()=>{
  if(document.getElementById('app').style.display !== 'none') cargar();
}, 30000);
</script>
</body>
</html>"""


if __name__ == "__main__":
    if not os.path.exists(PANEL_CFG):
        print(f"Falta {PANEL_CFG}. Ejecutar install-panel.sh primero.")
        raise SystemExit(1)
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
