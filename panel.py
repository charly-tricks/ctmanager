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


def estado_sistema():
    servicios = {}
    for s in ("ctmanager-limiter", "ctmanager-acct", "ctmanager-ws", "ssh", "sshd"):
        try:
            r = subprocess.run(["systemctl", "is-active", s],
                               capture_output=True, text=True, timeout=5)
            estado = r.stdout.strip()
            if estado != "inactive" or s in ("ctmanager-limiter", "ctmanager-acct", "ctmanager-ws"):
                servicios[s] = estado
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
    return {"servicios": servicios, "puertos": puertos}


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


@app.get("/api/datos")
async def datos(request: Request):
    exigir_sesion(request)
    return {"usuarios": leer_usuarios(), "sistema": estado_sistema()}


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
  .linea{display:flex;justify-content:space-between;padding:9px 0;
         border-bottom:1px solid var(--line);font-family:var(--mono);font-size:12px}
  .linea:last-child{border:none}
  .linea span:first-child{color:var(--dim)}
  .ok{color:var(--alive)} .mal{color:var(--dead)}

  .vacio{text-align:center;color:var(--dim);padding:32px 16px;font-size:14px}

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
      <label>Usuario</label>
      <input id="nUsuario" placeholder="juan" autocapitalize="off">
      <label>Contraseña</label>
      <input id="nClave" placeholder="dejar vacío para generar una">
      <div class="duo">
        <div><label>Días</label><input id="nDias" type="number" value="30" inputmode="numeric"></div>
        <div><label>Dispositivos</label><input id="nDisp" type="number" value="1" inputmode="numeric"></div>
      </div>
      <label>Datos en GB (0 = sin límite)</label>
      <input id="nGb" type="number" value="0" inputmode="numeric">
      <button class="principal" onclick="crear()">Crear cuenta</button>
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
    cargar();
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

  const s = d.sistema || {servicios:{}, puertos:[]};
  let html = '';
  const nombres = {
    'ctmanager-limiter':'Límite de dispositivos',
    'ctmanager-acct':'Contador de datos',
    'ctmanager-ws':'Proxy WebSocket',
    'ssh':'Servidor SSH', 'sshd':'Servidor SSH'
  };
  for(const [k,v] of Object.entries(s.servicios)){
    const vivo = v === 'active';
    html += `<div class="linea"><span>${nombres[k]||k}</span>
             <span class="${vivo?'ok':'mal'}">${vivo?'activo':v}</span></div>`;
  }
  if(s.puertos.length){
    html += `<div class="linea"><span>Puertos abiertos</span><span>${
      s.puertos.map(p=>p.puerto).join(' · ')}</span></div>`;
  }
  document.getElementById('sistema').innerHTML = html;

  document.getElementById('reloj').textContent =
    new Date().toLocaleTimeString('es-AR',{hour:'2-digit',minute:'2-digit'});
}

async function crear(){
  const usuario = document.getElementById('nUsuario').value.trim().toLowerCase();
  if(!usuario){ avisar('Escribí un nombre de usuario', true); return; }
  let clave = document.getElementById('nClave').value.trim();
  if(!clave){
    const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    clave = Array.from({length:10}, ()=> abc[Math.floor(Math.random()*abc.length)]).join('');
  }
  const d = await pedir('/api/crear', {
    usuario, clave,
    dias: +document.getElementById('nDias').value || 30,
    dispositivos: +document.getElementById('nDisp').value || 1,
    gb: +document.getElementById('nGb').value || 0
  });
  if(d.ok){
    avisar('Cuenta creada: ' + usuario + ' / ' + clave);
    document.getElementById('nUsuario').value = '';
    document.getElementById('nClave').value = '';
    cargar();
  } else {
    avisar(d.error || 'No se pudo crear', true);
  }
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
    cargar();
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
