#!/usr/bin/env bash
# Instala server-alerts en uno o varios servidores DESDE TU ORDENADOR.
# No hace falta zip/unzip: copia la carpeta por SSH y ejecuta install.sh,
# que te pregunta el nombre de cada servidor.
#
#   ./deploy.sh root@203.0.113.10
#   ./deploy.sh root@203.0.113.10 ubuntu@203.0.113.11
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -eq 0 ]]; then
  sed -n '2,7p' "$0"
  exit 1
fi

if [[ ! -f config.env ]]; then
  echo "AVISO: no existe config.env (cp config.env.example config.env y rellénalo)."
  echo "       El instalador te pedirá token y chat_id en cada servidor."
fi

REMOTE_DIR="/tmp/server-alerts-install"
FAILED=()

for target in "$@"; do
  echo
  echo "################  $target  ################"
  # COPYFILE_DISABLE evita los ficheros ._* de macOS dentro del tar.
  if COPYFILE_DISABLE=1 tar czf - --exclude .DS_Store --exclude .git --exclude '*.zip' . |
      ssh "$target" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar --warning=no-unknown-keyword -xzf - -C $REMOTE_DIR" &&
    ssh -t "$target" "if [ \"\$(id -u)\" -eq 0 ]; then bash $REMOTE_DIR/install.sh; else sudo bash $REMOTE_DIR/install.sh; fi; rc=\$?; rm -rf $REMOTE_DIR; exit \$rc"; then
    echo "OK: $target"
  else
    echo "FALLÓ: $target"
    FAILED+=("$target")
  fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Fallaron: ${FAILED[*]}"
  exit 1
fi
echo "Todo instalado."
