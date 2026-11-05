#!/usr/bin/env bash
# Aviso de login SSH. Lo llama pam_exec en cada sesión (PAM_TYPE=open_session).
# Nunca debe romper ni retrasar el login: siempre sale 0.

set -u
SA_TAG="ssh-notify"
. "$(dirname "$(readlink -f "$0")")/common.sh"

# pam_exec también se ejecuta al cerrar sesión: solo nos interesa la apertura.
if [[ -n "${PAM_TYPE:-}" && "$PAM_TYPE" != "open_session" ]]; then
  exit 0
fi

# Desde PAM, seguir en segundo plano: geo + Telegram pueden tardar varios
# segundos y pam_exec espera a que el script termine antes de dar la shell.
if [[ -n "${PAM_SERVICE:-}" && -z "${SA_DETACHED:-}" ]]; then
  SA_DETACHED=1 setsid "$0" </dev/null >/dev/null 2>&1 &
  exit 0
fi

USER_NAME="${PAM_USER:-${USER:-}}"
if [[ -z "$USER_NAME" ]]; then
  sa_log "skip: PAM_USER vacío"
  exit 0
fi

# IP remota: PAM_RHOST suele bastar; fallback a SSH_CLIENT / SSH_CONNECTION.
IP="${PAM_RHOST:-}"
[[ -z "$IP" && -n "${SSH_CLIENT:-}" ]] && IP="${SSH_CLIENT%% *}"
[[ -z "$IP" && -n "${SSH_CONNECTION:-}" ]] && IP="${SSH_CONNECTION%% *}"
[[ -z "$IP" ]] && IP="desconocida"

case " $IGNORE_USERS " in *" $USER_NAME "*) sa_log "ignorado usuario $USER_NAME"; exit 0 ;; esac
case " $IGNORE_IPS " in *" $IP "*) sa_log "ignorada IP $IP"; exit 0 ;; esac

HORA="$(date '+%Y-%m-%d %H:%M %Z')"

_is_public_ip() {
  local ip="$1"
  # Solo IPs literales (PAM_RHOST puede ser un hostname si sshd tiene UseDNS).
  [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  case "$ip" in
    127.*|0.0.0.0|::1) return 1 ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|169.254.*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;; # CGNAT / Tailscale
    [fF][cCdD]*|[fF][eE]80*) return 1 ;;
  esac
  return 0
}

# Geolocalización: nunca bloquear si falla.
LOCATION="desconocida"
if _is_public_ip "$IP" && command -v python3 >/dev/null 2>&1; then
  GEO_JSON="$(curl -sS --max-time 3 -A "server-alerts/1.0" "https://ipapi.co/${IP}/json/" 2>/dev/null || true)"
  if [[ -n "$GEO_JSON" ]]; then
    GEO="$(printf '%s' "$GEO_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("error"):
    sys.exit(0)
parts = [p for p in (d.get("city"), d.get("country_name") or d.get("country")) if p]
print(", ".join(parts))
' 2>/dev/null || true)"
    [[ -n "$GEO" ]] && LOCATION="$GEO"
  fi
fi

sa_send "🔐 SSH en ${SERVER_NAME}
Usuario: ${USER_NAME}
IP: ${IP}
Ubicación: ${LOCATION}
Hora: ${HORA}"

exit 0
