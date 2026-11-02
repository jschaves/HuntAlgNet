#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_USER="${APP_USER:-huntalgnet}"
APP_DIR="${APP_DIR:-/opt/huntalgnet}"
SOURCE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta este script como root." >&2
  exit 1
fi

if [[ "${SOURCE_DIR}" != "${APP_DIR}" ]]; then
  rsync -a --delete \
    --exclude '.git' --exclude '.env' --exclude 'venv' --exclude '__pycache__' \
    --exclude '.pytest_cache' --exclude 'logs' --exclude 'media' --exclude 'static' \
    --exclude 'celerybeat-schedule' \
    "${SOURCE_DIR}/" "${APP_DIR}/"
fi

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
if [[ -f "${APP_DIR}/.env" ]]; then
  chown root:"${APP_USER}" "${APP_DIR}/.env"
  chmod 640 "${APP_DIR}/.env"
fi

runuser -u "${APP_USER}" -- bash -c "cd '${APP_DIR}' && venv/bin/pip install --disable-pip-version-check -r requirements.txt && venv/bin/alembic upgrade head"

install -m 644 "${APP_DIR}/deploy/systemd/huntalgnet-api.service" /etc/systemd/system/huntalgnet-api.service
install -m 644 "${APP_DIR}/deploy/systemd/huntalgnet-worker.service" /etc/systemd/system/huntalgnet-worker.service
install -m 644 "${APP_DIR}/deploy/systemd/huntalgnet-beat.service" /etc/systemd/system/huntalgnet-beat.service
install -m 644 "${APP_DIR}/deploy/systemd/huntalgnet-backup.service" /etc/systemd/system/huntalgnet-backup.service
install -m 644 "${APP_DIR}/deploy/systemd/huntalgnet-backup.timer" /etc/systemd/system/huntalgnet-backup.timer

chmod 750 "${APP_DIR}/deploy/install.sh" "${APP_DIR}/deploy/update.sh" "${APP_DIR}/deploy/backup.sh"

systemctl daemon-reload
systemctl restart huntalgnet-api huntalgnet-worker huntalgnet-beat
systemctl enable --now huntalgnet-backup.timer
nginx -t
systemctl reload nginx

echo "Actualización completada."
