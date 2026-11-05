#!/usr/bin/env bash
# Comprueba disco / RAM / CPU y avisa por Telegram si cruzan el umbral.
# Cooldown por métrica para no spamear y aviso cuando vuelve a la normalidad.
# Umbrales y cooldown: /opt/server-alerts/config.env

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

# _evaluate clave etiqueta valor umbral detalle
_evaluate() {
  local key="$1" label="$2" value="$3" limit="$4" detail="$5"
  local active_file="${STATE_DIR}/active_${key}"

  if (( value >= limit )); then
    if _cooldown_ok "$key"; then
      sa_send "⚠️ ${SERVER_NAME}: ${label} al ${value}%${detail:+ ${detail}}"
      date +%s >"${STATE_DIR}/cooldown_${key}" 2>/dev/null || true
      touch "$active_file" 2>/dev/null || true
      sa_log "ALERTA ${label} ${value}% ${detail}"
    else
      sa_log "${label} ${value}% (cooldown activo)"
    fi
  else
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
_evaluate ram "RAM" "${RAM_PCT:-0}" "$THRESHOLD_RAM" ""

# --- CPU: loadavg de 5 min / núcleos (el de 1 min da falsas alarmas por picos) ---
LOAD5="$(awk '{print $2}' /proc/loadavg)"
CORES="$(nproc 2>/dev/null || echo 1)"
case "$CORES" in ''|*[!0-9]*|0) CORES=1 ;; esac
CPU_PCT="$(awk -v l="$LOAD5" -v n="$CORES" 'BEGIN { printf "%d", l * 100 / n }')"
_evaluate cpu "CPU" "${CPU_PCT:-0}" "$THRESHOLD_CPU" "(load5 ${LOAD5} / ${CORES} cores)"

exit 0
