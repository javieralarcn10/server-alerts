# Configuración y funciones compartidas. Se carga desde los demás scripts:
#   . "$(dirname "$(readlink -f "$0")")/common.sh"
# Define SA_TAG antes de cargarlo para etiquetar las líneas del log.

SA_BIN="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SA_ROOT="$(dirname "$SA_BIN")"
SA_CONF="${SERVER_ALERTS_CONF:-$SA_ROOT/config.env}"
LOG="${SERVER_ALERTS_LOG:-/var/log/server-alerts.log}"
STATE_DIR="${SERVER_ALERTS_STATE:-/var/lib/server-alerts}"

# Valores por defecto; config.env los sobrescribe.
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
[[ -r "$SA_CONF" ]] && . "$SA_CONF"

[[ -n "$SERVER_NAME" ]] || SERVER_NAME="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo servidor)"
export TZ="$ALERT_TZ"

sa_log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S %Z') [${SA_TAG:-server-alerts}] $*"
  { printf '%s\n' "$line" >>"$LOG"; } 2>/dev/null || true
  [[ -t 2 ]] && printf '%s\n' "$line" >&2
  return 0
}

sa_send() {
  bash "$SA_BIN/telegram.sh" "$1" || true
}
