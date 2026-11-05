#!/usr/bin/env bash
# Instalador de server-alerts (Debian/Ubuntu). Se puede repetir sin problema:
# sirve también para actualizar o cambiar el nombre del servidor.
#
#   sudo ./install.sh                  # pregunta el nombre del servidor
#   sudo ./install.sh --name "Web-1"   # sin preguntas
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
INSTALL_ROOT="/opt/server-alerts"
CONF="$INSTALL_ROOT/config.env"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="session optional pam_exec.so seteuid $INSTALL_ROOT/bin/ssh-notify.sh"
LOG="/var/log/server-alerts.log"
STATE="/var/lib/server-alerts"
UNIT_DIR="/etc/systemd/system"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ask "Pregunta" "valor por defecto" -> imprime la respuesta (o el defecto sin terminal)
ask() {
  local prompt="$1" def="${2:-}" ans=""
  if { : </dev/tty; } 2>/dev/null; then
    if [[ -n "$def" ]]; then
      printf '%s [%s]: ' "$prompt" "$def" >/dev/tty
    else
      printf '%s: ' "$prompt" >/dev/tty
    fi
    IFS= read -r ans </dev/tty || true
  fi
  printf '%s' "${ans:-$def}"
}

is_placeholder() { [[ -z "$1" || "$1" == PEGA_AQUI* ]]; }

NAME_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name) NAME_ARG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) die "opción desconocida: $1 (usa --name \"Nombre\")" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "ejecuta como root: sudo ./install.sh"
command -v systemctl >/dev/null 2>&1 || die "hace falta systemd"

# --- 1. Dependencias -------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  info "Instalando dependencias (apt update + curl python3)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl python3 ca-certificates >/dev/null
else
  info "AVISO: no hay apt-get; asegúrate de tener curl y python3"
fi
command -v curl >/dev/null 2>&1 || die "no se pudo instalar curl"

# --- 2. Configuración: nombre + credenciales -------------------------------
# Defaults < instalación previa < config.env del paquete < lo que se pregunte.
SERVER_NAME=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
ALERT_TZ="Europe/Madrid"
THRESHOLD_DISK=80
THRESHOLD_RAM=80
THRESHOLD_CPU=80
COOLDOWN_MINUTES=60
IGNORE_IPS=""
IGNORE_USERS=""
# shellcheck source=/dev/null
[[ -r "$CONF" ]] && . "$CONF"

if [[ -r "$SRC/config.env" ]]; then
  PKG_TOKEN="$(. "$SRC/config.env"; printf '%s' "${TELEGRAM_BOT_TOKEN:-}")"
  PKG_CHAT="$(. "$SRC/config.env"; printf '%s' "${TELEGRAM_CHAT_ID:-}")"
  PKG_TZ="$(. "$SRC/config.env"; printf '%s' "${ALERT_TZ:-}")"
  is_placeholder "$PKG_TOKEN" || TELEGRAM_BOT_TOKEN="$PKG_TOKEN"
  is_placeholder "$PKG_CHAT" || TELEGRAM_CHAT_ID="$PKG_CHAT"
  [[ -n "$PKG_TZ" ]] && ALERT_TZ="$PKG_TZ"
fi

echo
if [[ -n "$NAME_ARG" ]]; then
  SERVER_NAME="$NAME_ARG"
else
  SERVER_NAME="$(ask "Nombre de este servidor (aparecerá en las alertas)" "${SERVER_NAME:-$(hostname)}")"
fi
SERVER_NAME="${SERVER_NAME//$'\n'/ }"
[[ -n "$SERVER_NAME" ]] || SERVER_NAME="$(hostname)"

if is_placeholder "$TELEGRAM_BOT_TOKEN"; then
  TELEGRAM_BOT_TOKEN="$(ask "Token del bot de Telegram")"
fi
if is_placeholder "$TELEGRAM_CHAT_ID"; then
  TELEGRAM_CHAT_ID="$(ask "Chat ID de Telegram")"
fi
is_placeholder "$TELEGRAM_BOT_TOKEN" && die "falta el token (rellena config.env o escríbelo al instalar)"
is_placeholder "$TELEGRAM_CHAT_ID" && die "falta el chat_id (rellena config.env o escríbelo al instalar)"

# --- 3. Archivos ------------------------------------------------------------
info "Instalando en $INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/extras" "$STATE"
chmod 700 "$INSTALL_ROOT" "$INSTALL_ROOT/bin"
for f in common.sh telegram.sh ssh-notify.sh resource-check.sh authlog-notify.sh; do
  install -o root -g root -m 0700 "$SRC/bin/$f" "$INSTALL_ROOT/bin/$f"
done
install -o root -g root -m 0700 "$SRC/uninstall.sh" "$INSTALL_ROOT/uninstall.sh"
install -m 0644 "$SRC/extras/"* "$INSTALL_ROOT/extras/"
install -m 0644 "$SRC/README.md" "$INSTALL_ROOT/README.md"

# config.env con permisos 600: contiene el token.
TMP_CONF="$(mktemp "$INSTALL_ROOT/.config.XXXXXX")"
cat >"$TMP_CONF" <<EOF
# server-alerts — configuración de ESTE servidor (generado por install.sh).
# Puedes editarlo: los cambios se aplican en la siguiente alerta.
SERVER_NAME=$(printf '%q' "$SERVER_NAME")
TELEGRAM_BOT_TOKEN=$(printf '%q' "$TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID=$(printf '%q' "$TELEGRAM_CHAT_ID")
ALERT_TZ=$(printf '%q' "$ALERT_TZ")

# Umbrales en % y minutos mínimos entre avisos repetidos de la misma métrica
THRESHOLD_DISK=$(printf '%q' "$THRESHOLD_DISK")
THRESHOLD_RAM=$(printf '%q' "$THRESHOLD_RAM")
THRESHOLD_CPU=$(printf '%q' "$THRESHOLD_CPU")
COOLDOWN_MINUTES=$(printf '%q' "$COOLDOWN_MINUTES")

# Opcional: IPs o usuarios (separados por espacios) que NO generan aviso SSH
IGNORE_IPS=$(printf '%q' "$IGNORE_IPS")
IGNORE_USERS=$(printf '%q' "$IGNORE_USERS")
EOF
chown root:root "$TMP_CONF"
chmod 600 "$TMP_CONF"
mv -f "$TMP_CONF" "$CONF"

touch "$LOG"
chown root:root "$LOG"
chmod 640 "$LOG"

cat >/etc/logrotate.d/server-alerts <<EOF
$LOG {
  monthly
  rotate 6
  compress
  missingok
  notifempty
  create 0640 root root
}
EOF

# --- 4. Aviso de login SSH (PAM; fallback auth.log) ------------------------
if [[ -f "$PAM_FILE" ]]; then
  if grep -Fq "$INSTALL_ROOT/bin/ssh-notify.sh" "$PAM_FILE"; then
    info "PAM ya configurado"
  else
    BACKUP="${PAM_FILE}.bak.server-alerts.$(date +%Y%m%d%H%M%S)"
    cp -a "$PAM_FILE" "$BACKUP"
    printf '\n# server-alerts: aviso Telegram en login SSH\n%s\n' "$PAM_LINE" >>"$PAM_FILE"
    info "PAM configurado (backup: $BACKUP)"
  fi
elif [[ -f /var/log/auth.log ]]; then
  info "No existe $PAM_FILE: activo el fallback que vigila /var/log/auth.log"
  install -m 0644 "$SRC/extras/sshd-authlog.path" "$UNIT_DIR/server-alerts-authlog.path"
  install -m 0644 "$SRC/extras/sshd-authlog.service" "$UNIT_DIR/server-alerts-authlog.service"
  AUTHLOG_FALLBACK=1
else
  info "AVISO: ni $PAM_FILE ni /var/log/auth.log: no habrá avisos de login SSH"
fi

# --- 5. Timer de recursos (cada 5 min, sobrevive a reinicios) --------------
install -m 0644 "$SRC/systemd/server-alerts-resources.service" "$UNIT_DIR/"
install -m 0644 "$SRC/systemd/server-alerts-resources.timer" "$UNIT_DIR/"
systemctl daemon-reload
systemctl enable --now server-alerts-resources.timer >/dev/null 2>&1
[[ "${AUTHLOG_FALLBACK:-0}" -eq 1 ]] && systemctl enable --now server-alerts-authlog.path >/dev/null 2>&1
info "Timer de recursos activo"

# --- 6. Prueba --------------------------------------------------------------
info "Enviando mensaje de prueba a Telegram..."
if bash "$INSTALL_ROOT/bin/telegram.sh" "✅ server-alerts instalado en ${SERVER_NAME}" 2>/dev/null; then
  TEST_RESULT="✅ mensaje de prueba enviado"
else
  TEST_RESULT="❌ no se pudo enviar (mira $LOG y revisa token/chat_id en $CONF)"
fi

cat <<MSG

---------------------------------------------------------
 server-alerts instalado en: ${SERVER_NAME}
 Telegram: ${TEST_RESULT}

 Cambiar nombre/ajustes:  sudo nano $CONF
 Ver log:                 sudo tail -f $LOG
 Desinstalar:             sudo $INSTALL_ROOT/uninstall.sh
---------------------------------------------------------
MSG
