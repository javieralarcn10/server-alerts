#!/usr/bin/env bash
# Comprueba disco / RAM / CPU y avisa por Telegram si cruzan el umbral.
# RAM y CPU solo avisan si el consumo se mantiene SUSTAIN_MINUTES seguidos
# (se mide cada minuto; una sola muestra por debajo reinicia la cuenta).
# Cooldown por métrica para no spamear y aviso cuando vuelve a la normalidad.
# Umbrales, duración y cooldown: /opt/server-alerts/config.env

set -u
SA_TAG="resource-check"
. "$(dirname "$(readlink -f "$0")")/common.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true

_cooldown_ok() {
  # 0 si se puede alertar (no hay cooldown activo para esta métrica).
  local stamp_file="${STATE_DIR}/cooldown_$1" now last
  [[ -f "$stamp_file" ]] || return 0
  now="$(date +%s)"
  last="$(cat "$stamp_file" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  (( now - last >= COOLDOWN_MINUTES * 60 ))
}

# _evaluate clave etiqueta valor umbral detalle [minutos_sostenido]
_evaluate() {
  local key="$1" label="$2" value="$3" limit="$4" detail="$5" sustain="${6:-0}"
  local active_file="${STATE_DIR}/active_${key}"
  local since_file="${STATE_DIR}/since_${key}"
  local now since elapsed=0 msg_extra=""

  if (( value >= limit )); then
    # ¿Desde cuándo está por encima? (se borra en cuanto baja del umbral)
    now="$(date +%s)"
    [[ -f "$since_file" ]] || echo "$now" >"$since_file" 2>/dev/null || true
    since="$(cat "$since_file" 2>/dev/null)"
    case "$since" in ''|*[!0-9]*) since="$now" ;; esac
    elapsed=$(( now - since ))

    if (( sustain > 0 )); then
      # Margen de 30 s porque el timer no cae exacto al segundo.
      if (( elapsed + 30 < sustain * 60 )); then
        sa_log "${label} ${value}% por encima del ${limit}% hace $(( elapsed / 60 )) min (avisa a los ${sustain})"
        return 0
      fi
      msg_extra=" durante $(( (elapsed + 30) / 60 )) min"
    fi

    if _cooldown_ok "$key"; then
      sa_send "⚠️ ${SERVER_NAME}: ${label} al ${value}%${msg_extra}${detail:+ ${detail}}"
      date +%s >"${STATE_DIR}/cooldown_${key}" 2>/dev/null || true
      touch "$active_file" 2>/dev/null || true
      sa_log "ALERTA ${label} ${value}% ${detail}"
    else
      sa_log "${label} ${value}% (cooldown activo)"
    fi
  else
    rm -f "$since_file" 2>/dev/null
    if [[ -f "$active_file" ]]; then
      sa_send "✅ ${SERVER_NAME}: ${label} de nuevo normal (${value}%)"
      rm -f "$active_file"
      sa_log "RECUPERADO ${label} ${value}%"
    else
      sa_log "${label} OK ${value}% (umbral ${limit}%)"
    fi
  fi
}

# --- Disco: peor % de los sistemas de archivos reales ---
read -r DISK_PCT DISK_MP < <(
  df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null |
    awk 'NR > 1 { u = $(NF-1); sub(/%/, "", u); if (u + 0 > w) { w = u + 0; m = $NF } }
         END { print w + 0, (m == "" ? "/" : m) }'
)
_evaluate disk "Disco" "${DISK_PCT:-0}" "$THRESHOLD_DISK" "en ${DISK_MP:-/}"

# --- RAM: (MemTotal - MemAvailable) / MemTotal ---
RAM_PCT="$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
               END { if (t > 0) printf "%d", (t - a) * 100 / t; else print 0 }' /proc/meminfo)"
_evaluate ram "RAM" "${RAM_PCT:-0}" "$THRESHOLD_RAM" "" "$SUSTAIN_MINUTES"

# --- CPU: % real de uso desde la ejecución anterior (~1 min), vía /proc/stat ---
# user+nice+system+irq+softirq+steal sobre el total (sin idle ni iowait).
CPU_NOW="$(awk '/^cpu / { busy = $2 + $3 + $4 + $7 + $8 + $9; total = busy + $5 + $6; print busy, total; exit }' /proc/stat)"
CPU_PREV_FILE="${STATE_DIR}/cpu_prev"
CPU_PREV="$(cat "$CPU_PREV_FILE" 2>/dev/null)"
echo "$CPU_NOW" >"$CPU_PREV_FILE" 2>/dev/null || true
CPU_PCT="$(awk -v now="$CPU_NOW" -v prev="$CPU_PREV" 'BEGIN {
  split(now, n, " "); split(prev, p, " ")
  dt = n[2] - p[2]
  if (prev == "" || dt <= 0) { print "-"; exit }
  printf "%d", (n[1] - p[1]) * 100 / dt }')"
if [[ "$CPU_PCT" == "-" ]]; then
  sa_log "CPU: primera muestra, se evalúa en la siguiente ejecución"
else
  _evaluate cpu "CPU" "$CPU_PCT" "$THRESHOLD_CPU" "" "$SUSTAIN_MINUTES"
fi

exit 0
