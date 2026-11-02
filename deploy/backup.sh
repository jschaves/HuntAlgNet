#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_DIR="${APP_DIR:-/opt/huntalgnet}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/huntalgnet}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
ENV_FILE="${APP_DIR}/.env"
KEY_FILE="/etc/huntalgnet/backup.key"

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT

read_env() {
  local key="$1" file="${2:-$ENV_FILE}" value
  [[ -f "$file" ]] || return 0
  value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

[[ -r "$ENV_FILE" ]] || die "No se puede leer ${ENV_FILE}"
[[ -r "$KEY_FILE" ]] || die "No se puede leer ${KEY_FILE}"

DB_NAME="$(read_env DB_NAME)"
DB_USER="$(read_env DB_USER)"
DB_PASSWORD="$(read_env DB_PASSWORD)"
[[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASSWORD" ]] || die "Faltan variables de base de datos"

install -d -m 0700 "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

PGPASSWORD="$DB_PASSWORD" pg_dump \
  -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -Fc \
  | gpg --batch --yes --no-tty --symmetric --cipher-algo AES256 \
      --passphrase-file "$KEY_FILE" \
      -o "${BACKUP_DIR}/db-${STAMP}.dump.gpg"

if [[ -d "${APP_DIR}/media" ]]; then
  tar -czf - -C "$APP_DIR" media \
    | gpg --batch --yes --no-tty --symmetric --cipher-algo AES256 \
        --passphrase-file "$KEY_FILE" \
        -o "${BACKUP_DIR}/media-${STAMP}.tar.gz.gpg"
fi

find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete

printf 'Backup cifrado completado en %s (%s).\n' "$BACKUP_DIR" "$STAMP"
