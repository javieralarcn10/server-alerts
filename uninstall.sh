#!/usr/bin/env bash
# Desinstalador de server-alerts. Con --purge también borra el log.
#   sudo /opt/server-alerts/uninstall.sh [--purge]
set -euo pipefail

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ "$(id -u)" -eq 0 ]] || die "ejecuta como root: sudo $0 [--purge]"

PAM_FILE="/etc/pam.d/sshd"

systemctl disable --now server-alerts-resources.timer 2>/dev/null || true
systemctl disable --now server-alerts-authlog.path 2>/dev/null || true
rm -f /etc/systemd/system/server-alerts-resources.service \
      /etc/systemd/system/server-alerts-resources.timer \
      /etc/systemd/system/server-alerts-authlog.service \
      /etc/systemd/system/server-alerts-authlog.path
systemctl daemon-reload 2>/dev/null || true

if [[ -f "$PAM_FILE" ]] && grep -Fq "/opt/server-alerts/bin/ssh-notify.sh" "$PAM_FILE"; then
  BACKUP="${PAM_FILE}.bak.uninstall.$(date +%Y%m%d%H%M%S)"
  cp -a "$PAM_FILE" "$BACKUP"
  sed -i '/server-alerts: aviso Telegram/d;/pam_exec.so seteuid \/opt\/server-alerts\/bin\/ssh-notify.sh/d' "$PAM_FILE"
  info "Eliminada línea pam_exec (backup: $BACKUP)"
fi

rm -f /etc/logrotate.d/server-alerts
rm -rf /opt/server-alerts /var/lib/server-alerts
# Restos de versiones antiguas
rm -f /etc/server-alerts.env

if [[ "$PURGE" -eq 1 ]]; then
  rm -f /var/log/server-alerts.log*
  info "Purge: log borrado"
else
  info "Se conserva /var/log/server-alerts.log (usa --purge para borrarlo)"
fi

info "Desinstalado."
