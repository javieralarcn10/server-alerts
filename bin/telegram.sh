#!/usr/bin/env bash
# Envía un mensaje a Telegram. Uso: telegram.sh "texto"
# Token y chat_id se leen de /opt/server-alerts/config.env.
# Sale 1 si no se pudo enviar (quien lo llama usa `|| true`, así nunca bloquea).

set -u
SA_TAG="telegram"
. "$(dirname "$(readlink -f "$0")")/common.sh"

TEXT="${1:-}"
if [[ -z "$TEXT" ]]; then
  sa_log "ERROR: mensaje vacío"
  exit 1
fi

if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || "$TELEGRAM_BOT_TOKEN" == PEGA_AQUI* ]]; then
  sa_log "ERROR: falta TELEGRAM_BOT_TOKEN o TELEGRAM_CHAT_ID en $SA_CONF"
  exit 1
fi

if [[ "${SERVER_ALERTS_DRY_RUN:-}" == "1" ]]; then
  sa_log "DRY-RUN: no se envía (chat_id=${TELEGRAM_CHAT_ID})"
  printf '%s\n' "$TEXT"
  exit 0
fi

# La URL lleva el token: se pasa por stdin (-K -) para que no aparezca en `ps`.
if ! RESP="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
    curl -sS --max-time 10 -K - \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${TEXT}" \
      --data-urlencode "disable_web_page_preview=true" 2>&1)"; then
  sa_log "ERROR: curl falló: $RESP"
  exit 1
fi

if [[ "$RESP" != *'"ok":true'* ]]; then
  sa_log "ERROR: Telegram rechazó el mensaje: $RESP"
  exit 1
fi

sa_log "OK: mensaje enviado"
exit 0
