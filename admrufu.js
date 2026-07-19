// ============================================================
//  admrufu.js  -  REEMPLAZO SIN ADMRufu
//  by CHARLY_TRICKS
//
//  Mantiene EXACTAMENTE los mismos nombres de funciones y el
//  mismo formato de respuesta que la version original, asi que
//  index.js y bot.js no necesitan ningun cambio.
//
//  La diferencia: en vez de mandar comandos al socket de ADMRufu,
//  llama a /usr/local/bin/ctmanager-cli.
//
//  Requisito: ctmanager-cli instalado en el mismo VPS.
//  Si el bot corre en otro servidor, ver CTMANAGER_SSH abajo.
// ============================================================

const { execFile } = require('child_process');
const fs = require('fs');

const cfg = JSON.parse(fs.readFileSync(__dirname + '/config.json', 'utf8'));

const CLI = cfg.ctmanager_cli || '/usr/local/bin/ctmanager-cli';
const CONEXIONES = cfg.conexiones_por_cuenta || 1;
const DIAS_CUENTA = cfg.dias_cuenta || 30;

// Si el CLI vive en OTRO servidor, poner en config.json:
//   "ctmanager_ssh": "root@1.2.3.4"
// y tener clave SSH sin passphrase configurada.
const SSH_HOST = cfg.ctmanager_ssh || null;

function generarPassword(longitud = 10) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  let p = '';
  for (let i = 0; i < longitud; i++) {
    p += chars[Math.floor(Math.random() * chars.length)];
  }
  return p;
}

// ------------------------------------------------------------
//  Ejecucion del CLI
// ------------------------------------------------------------
// Recibe un array de argumentos (NO un string), asi no hay shell
// de por medio y nadie puede inyectar comandos a traves del
// nombre de usuario.
function ejecutarCLI(args) {
  return new Promise((resolve) => {
    let cmd, argv;
    if (SSH_HOST) {
      cmd = 'ssh';
      argv = ['-o', 'StrictHostKeyChecking=no', SSH_HOST, CLI, ...args];
    } else {
      cmd = CLI;
      argv = args;
    }
    execFile(cmd, argv, { timeout: 30000 }, (err, stdout, stderr) => {
      const salida = ((stdout || '') + (stderr || '')).trim();
      resolve(salida);
    });
  });
}

// Igual que la anterior pero parseando la salida JSON del CLI.
async function ejecutarJSON(args) {
  const salida = await ejecutarCLI([...args, '--json']);
  try {
    return JSON.parse(salida);
  } catch (e) {
    return { ok: false, error: salida || 'sin respuesta del CLI' };
  }
}

// Compatibilidad: el resto del bot puede llamar ejecutarComando()
// con un string estilo ADMRufu. Lo traducimos.
function ejecutarComando(comando) {
  const partes = String(comando).trim().split(/\s+/);
  // "/ssh add user pass conex dias" -> ["add","user","pass","dias","conex"]
  if (partes[0] === '/ssh' && partes[1] === 'add') {
    return ejecutarCLI(['add', partes[2], partes[3], partes[5] || String(DIAS_CUENTA), partes[4] || '1']);
  }
  if (partes[0] === '/ssh' && partes[1] === 'info') {
    return ejecutarCLI(['info', partes[2]]);
  }
  if (partes[0] === '/ssh' && partes[1] === 'del') {
    return ejecutarCLI(['del', partes[2]]);
  }
  // Cualquier otra cosa: no hay equivalente, devolvemos vacio.
  return Promise.resolve('');
}

function formatDatos(mb) {
  if (mb >= 1024 && mb % 1024 === 0) return (mb / 1024) + ' GB';
  if (mb >= 1024) return (Math.round((mb / 1024) * 100) / 100) + ' GB';
  return Math.round(mb) + ' MB';
}

// ============================================================
//  CUENTAS SSH (usuario / contraseña)
// ============================================================

async function crearCuentaDatos(usuario, mb) {
  const password = generarPassword();
  const usuarioLimpio = String(usuario).toLowerCase().trim();
  const mbEntero = Math.round(mb);

  // 1) Crear la cuenta (dias y limite de dispositivos)
  const alta = await ejecutarJSON([
    'add', usuarioLimpio, password, String(DIAS_CUENTA), String(CONEXIONES), '0'
  ]);

  if (!alta.ok) {
    return { success: false, error: alta.error || 'no se pudo crear la cuenta' };
  }

  // 2) Aplicar la cuota de datos en MB
  const cuota = await ejecutarJSON(['quota', usuarioLimpio, String(mbEntero), 'MB']);
  if (!cuota.ok) {
    // Rollback: si no se pudo poner la cuota, no dejamos la cuenta suelta
    await ejecutarJSON(['del', usuarioLimpio]);
    return { success: false, error: cuota.error || 'no se pudo aplicar la cuota' };
  }

  return { success: true, user: usuarioLimpio, password, mb: mbEntero };
}

async function leerLimiteMB(usuario) {
  const r = await ejecutarJSON(['usage', String(usuario).toLowerCase().trim()]);
  if (!r.ok) return 0;
  return Math.round(r.cuota_mb || 0);
}

async function recargarDatos(usuario, mbNuevos) {
  const usuarioLimpio = String(usuario).toLowerCase().trim();
  const nuevoTotalMB = Math.round(mbNuevos);

  // 1) Poner el contador de consumo en cero
  await ejecutarJSON(['reset-usage', usuarioLimpio]);

  // 2) Fijar el nuevo total de datos
  const cuota = await ejecutarJSON(['quota', usuarioLimpio, String(nuevoTotalMB), 'MB']);

  // 3) Sumar dias
  await ejecutarJSON(['renew', usuarioLimpio, String(DIAS_CUENTA)]);

  // 4) Asegurar que quede desbloqueada
  await ejecutarJSON(['unlock', usuarioLimpio]);

  return {
    success: !!cuota.ok,
    totalMB: nuevoTotalMB,
    dias: DIAS_CUENTA,
    respuesta: cuota.ok ? 'limite actualizado' : (cuota.error || 'error')
  };
}

async function infoCuenta(usuario) {
  const usuarioLimpio = String(usuario).toLowerCase().trim();
  const r = await ejecutarJSON(['usage', usuarioLimpio]);
  if (!r.ok) return 'Usuario no encontrado';

  const restante = r.restante || 'ilimitado';
  const venceEl = (r.expira || '').split(' ')[0] || 'sin limite';
  const estado = r.activo === 1 ? 'Activo' : 'Bloqueado';

  // Se deja "Limit:" en el texto porque el bot original lo parsea asi.
  return [
    `Usuario: ${usuarioLimpio}`,
    `Estado: ${estado}`,
    `Limit: ${formatDatos(r.cuota_mb || 0)}`,
    `Consumido: ${r.usado || '0 MB'}`,
    `Restante: ${restante}`,
    `Expira: ${venceEl}`
  ].join('\n');
}

// ============================================================
//  CUENTAS POR HWID
// ============================================================
// El servidor SSH no distingue: una cuenta HWID es simplemente una
// cuenta cuyo usuario Y contraseña son el HWID del dispositivo.
// Por eso reutilizamos las mismas funciones.

function validarHwid(hwid) {
  return /^[a-fA-F0-9]{32}$/.test((hwid || '').trim());
}

async function crearCuentaHwid(hwid, nombre, mb) {
  const h = String(hwid).toLowerCase().trim();
  if (!validarHwid(h)) {
    return { success: false, error: 'HWID invalido (deben ser 32 caracteres hexadecimales)' };
  }

  const mbEntero = Math.round(mb);

  const alta = await ejecutarJSON([
    'add', h, h, String(DIAS_CUENTA), String(CONEXIONES), '0'
  ]);

  // Si ya existia, recargamos en vez de fallar (mismo comportamiento
  // que la version original).
  if (!alta.ok && alta.code === 4) {
    const r = await recargarHwid(h, mbEntero);
    if (r.success) return { success: true, hwid: h, nombre, mb: mbEntero, recargada: true };
    return { success: false, error: 'No se pudo recargar la cuenta existente: ' + r.respuesta };
  }

  if (!alta.ok) {
    return { success: false, error: alta.error || 'no se pudo crear la cuenta' };
  }

  const cuota = await ejecutarJSON(['quota', h, String(mbEntero), 'MB']);
  if (!cuota.ok) {
    await ejecutarJSON(['del', h]);
    return { success: false, error: cuota.error || 'no se pudo aplicar la cuota' };
  }

  return { success: true, hwid: h, nombre, mb: mbEntero };
}

async function leerLimiteHwidMB(hwid) {
  return await leerLimiteMB(String(hwid).toLowerCase().trim());
}

async function recargarHwid(hwid, mbNuevos) {
  return await recargarDatos(String(hwid).toLowerCase().trim(), mbNuevos);
}

// ============================================================
module.exports = {
  crearCuentaDatos,
  recargarDatos,
  leerLimiteMB,
  infoCuenta,
  generarPassword,
  ejecutarComando,
  crearCuentaHwid,
  recargarHwid,
  leerLimiteHwidMB,
  validarHwid
};
