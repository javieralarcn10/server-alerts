#!/usr/bin/env bash
# Fallback (solo si no hay /etc/pam.d/sshd): parsea la última aceptación SSH
# de /var/log/auth.log (o secure). Evita duplicados con un fingerprint.

set -u
SA_TAG="authlog-notify"
. "$(dirname "$(readlink -f "$0")")/common.sh"

AUTH_LOG=""
for candidate in /var/log/auth.log /var/log/secure; do
  if [[ -r "$candidate" ]]; then
    AUTH_LOG="$candidate"
    break
  fi
done
[[ -z "$AUTH_LOG" ]] && exit 0

mkdir -p "$STATE_DIR" 2>/dev/null || true
LAST_FILE="${STATE_DIR}/last_authlog_event"

# Línea típica (OpenSSH >= 9.8 escribe "sshd-session" en vez de "sshd"):
# Oct 21 18:40:01 host sshd[1234]: Accepted publickey for ubuntu from 1.2.3.4 port 22 ssh2
LINE="$(grep -E 'sshd(-session)?\[[0-9]+\]: Accepted [a-z-]+ for ' "$AUTH_LOG" | tail -n 1 || true)"
[[ -z "$LINE" ]] && exit 0

FINGERPRINT="$(printf '%s' "$LINE" | sha256sum | awk '{print $1}')"
if [[ "$(cat "$LAST_FILE" 2>/dev/null)" == "$FINGERPRINT" ]]; then
  exit 0
fi
printf '%s\n' "$FINGERPRINT" >"$LAST_FILE" 2>/dev/null || true

USER_NAME="$(printf '%s' "$LINE" | sed -nE 's/.* for ([^ ]+) from .*/\1/p')"
IP="$(printf '%s' "$LINE" | sed -nE 's/.* from ([0-9a-fA-F:.]+) port .*/\1/p')"
[[ -z "$USER_NAME" ]] && exit 0

export PAM_TYPE=open_session
export PAM_USER="$USER_NAME"
export PAM_RHOST="${IP:-desconocida}"
exec bash "$SA_BIN/ssh-notify.sh"
