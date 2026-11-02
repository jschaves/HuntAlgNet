#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP_USER="huntalgnet"
APP_DIR="/opt/huntalgnet"
BACKUP_DIR="/var/backups/huntalgnet"
BACKUP_KEY_FILE="/etc/huntalgnet/backup.key"
ADMIN_CRED_FILE="/root/huntalgnet-initial-credentials.txt"
ENV_FILE="${APP_DIR}/.env"
ACME_ROOT="/var/www/huntalgnet-acme"
SSL_DIR="/etc/ssl/huntalgnet"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
YOUTUBE_SCOPES="${YOUTUBE_SCOPES:-https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/yt-analytics.readonly https://www.googleapis.com/auth/youtube.upload}"
OLLAMA_VERSION="${OLLAMA_VERSION:-}"
OLLAMA_INSTALL_SHA256="${OLLAMA_INSTALL_SHA256:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
INSTALL_AI="${INSTALL_AI:-}"
INSTALL_AI_SET=0
if [[ -n "$INSTALL_AI" ]]; then
  INSTALL_AI_SET=1
fi
ENABLE_FIREWALL="${ENABLE_FIREWALL:-1}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-1}"
HARDEN_SYSCTL="${HARDEN_SYSCTL:-1}"
HARDEN_SSH="${HARDEN_SSH:-0}"

REPO_URL="${REPO_URL:-https://github.com/jschaves/HuntAlgNet.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
USE_LOCAL_REPO="${USE_LOCAL_REPO:-1}"
FORCE_CLONE="${FORCE_CLONE:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
INTERACTIVE=0
CLONE_DIR=""
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SOURCE" && -f "$SCRIPT_SOURCE" ]]; then
  REPO_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")/.." 2>/dev/null && pwd || true)"
else
  REPO_DIR=""
fi

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "$CLONE_DIR" && -d "$CLONE_DIR" ]]; then
    rm -rf "$CLONE_DIR"
  fi
}
trap cleanup EXIT
trap 'die "Fallo inesperado en la linea ${LINENO}"' ERR

usage() {
  cat <<'EOF'
Uso: bash deploy/install.sh [opciones]

Descarga el repositorio automaticamente si el script no se ejecuta desde un
checkout local. Si no se indica dominio, se instala en modo local (localhost).

Variables de entorno:
  DOMAIN=dominio.com          Dominio publico (si se omite se usa localhost)
  EMAIL=admin@dominio.com     Email para Let's Encrypt
  ADMIN_EMAIL=...             Email del superadministrador
  ADMIN_PASSWORD=...          Contrasena inicial (si se omite se genera)
  GOOGLE_CLIENT_ID=...        Credencial OAuth de Google
  GOOGLE_CLIENT_SECRET=...    Secreto OAuth de Google
  REPO_URL=...                Repositorio git a descargar
  REPO_BRANCH=...             Rama del repositorio (por defecto main)
  INSTALL_AI=0|1              Instalar Ollama y modelo (por defecto 1)
  OLLAMA_VERSION=...          Version de Ollama a instalar
  OLLAMA_INSTALL_SHA256=...   Checksum SHA256 del instalador de Ollama
  OLLAMA_MODEL=...            Modelo a descargar
  ENABLE_FIREWALL=0|1         Configurar UFW (por defecto 1)
  ENABLE_FAIL2BAN=0|1         Configurar fail2ban (por defecto 1)
  HARDEN_SYSCTL=0|1           Aplicar sysctl de seguridad (por defecto 1)
  HARDEN_SSH=0|1              Endurecer SSH (por defecto 0, evita bloqueos)
  ASSUME_YES=0|1              No hacer preguntas (por defecto 0)

Opciones:
  --domain VALUE
  --email VALUE
  --admin-email VALUE
  --admin-password VALUE
  --ollama-model VALUE
  --repo-url VALUE
  --repo-branch VALUE
  --localhost
  --yes
  --force-clone
  --use-local
  --no-ai
  --no-firewall
  --no-fail2ban
  --harden-ssh
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="${2:-}"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="${2:-}"; shift 2 ;;
    --ollama-model) OLLAMA_MODEL="${2:-}"; shift 2 ;;
    --repo-url) REPO_URL="${2:-}"; shift 2 ;;
    --repo-branch) REPO_BRANCH="${2:-}"; shift 2 ;;
    --localhost) DOMAIN="localhost"; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --force-clone) FORCE_CLONE=1; shift ;;
    --use-local) USE_LOCAL_REPO=1; shift ;;
    --no-ai) INSTALL_AI=0; INSTALL_AI_SET=1; shift ;;
    --no-firewall) ENABLE_FIREWALL=0; shift ;;
    --no-fail2ban) ENABLE_FAIL2BAN=0; shift ;;
    --harden-ssh) HARDEN_SSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opcion desconocida: $1" ;;
  esac
done

if [[ "$ASSUME_YES" -eq 0 ]] && { [[ -t 0 ]] || [[ -r /dev/tty ]]; }; then
  INTERACTIVE=1
fi

ask() {
  local prompt="$1" default="$2" value=""
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    if [[ -t 0 ]]; then
      read -r -p "$prompt" value || true
    else
      read -r -p "$prompt" value < /dev/tty || true
    fi
  fi
  printf '%s' "${value:-$default}"
}

ask_secret() {
  local prompt="$1" value=""
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    if [[ -t 0 ]]; then
      read -rs -p "$prompt" value || true
    else
      read -rs -p "$prompt" value < /dev/tty || true
    fi
    printf '\n'
  fi
  printf '%s' "$value"
}

[[ "${EUID}" -eq 0 ]] || die "Ejecuta este instalador como root."
[[ -f /etc/os-release ]] || die "No se puede detectar el sistema operativo."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Solo se soportan Ubuntu y Debian." ;;
esac
command -v systemctl >/dev/null 2>&1 || die "systemd es obligatorio."
if [[ -z "$DOMAIN" ]]; then
  DOMAIN="$(ask "Dominio publico (Enter para localhost): " "localhost")"
fi
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN%%/*}"
DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN:-localhost}"

if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  IS_IP=1
else
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "Dominio invalido: $DOMAIN"
  IS_IP=0
fi

if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == "127.0.0.1" ]]; then
  IS_LOCAL=1
  HTTP_LISTEN="127.0.0.1:80"
  HTTP_LISTEN6="[::1]:80"
  HTTPS_LISTEN="127.0.0.1:443"
  HTTPS_LISTEN6="[::1]:443"
else
  IS_LOCAL=0
  HTTP_LISTEN="80"
  HTTP_LISTEN6="[::]:80"
  HTTPS_LISTEN="443"
  HTTPS_LISTEN6="[::]:443"
fi

if [[ "$IS_LOCAL" -eq 0 && -z "$EMAIL" ]]; then
  EMAIL="$(ask "Email para Let's Encrypt (opcional, Enter para omitir): " "")"
fi
if [[ -n "$EMAIL" && "$EMAIL" != *"@"* ]]; then
  die "EMAIL invalido."
fi

DEFAULT_ADMIN_EMAIL="admin@example.com"
if [[ "$IS_IP" -eq 0 && "$IS_LOCAL" -eq 0 && "$DOMAIN" == *.* ]]; then
  DEFAULT_ADMIN_EMAIL="admin@${DOMAIN}"
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
  ADMIN_EMAIL="$(ask "Email del superadministrador [${DEFAULT_ADMIN_EMAIL}]: " "$DEFAULT_ADMIN_EMAIL")"
fi
ADMIN_EMAIL="${ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"
[[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "ADMIN_EMAIL invalido."

if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(ask_secret "Contrasena del superadministrador (Enter para generar): ")"
fi
if [[ -n "$ADMIN_PASSWORD" ]]; then
  (( ${#ADMIN_PASSWORD} >= 8 )) || die "ADMIN_PASSWORD debe tener al menos 8 caracteres."
  if [[ "$ADMIN_PASSWORD" == *"'"* || "$ADMIN_PASSWORD" == *$'\n'* ]]; then
    die "ADMIN_PASSWORD no puede contener comillas simples ni saltos de linea."
  fi
fi

if [[ -z "$GOOGLE_CLIENT_ID" ]]; then
  GOOGLE_CLIENT_ID="$(ask "GOOGLE_CLIENT_ID (opcional, Enter para omitir): " "")"
fi
if [[ -n "$GOOGLE_CLIENT_ID" && -z "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_CLIENT_SECRET="$(ask_secret "GOOGLE_CLIENT_SECRET: ")"
fi

if [[ -n "$GOOGLE_CLIENT_ID" && ! "$GOOGLE_CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "GOOGLE_CLIENT_ID contiene caracteres invalidos."
fi
if [[ -n "$GOOGLE_CLIENT_SECRET" && ! "$GOOGLE_CLIENT_SECRET" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "GOOGLE_CLIENT_SECRET contiene caracteres invalidos."
fi

if [[ "$INSTALL_AI_SET" -eq 0 ]]; then
  AI_ANSWER="$(ask "Instalar IA local con Ollama? [S/n]: " "S")"
  case "${AI_ANSWER,,}" in
    n|no) INSTALL_AI=0 ;;
    *) INSTALL_AI=1 ;;
  esac
fi
INSTALL_AI="${INSTALL_AI:-1}"

if [[ -z "$OLLAMA_MODEL" ]]; then
  MEM_GB="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || printf '0')"
  if (( MEM_GB >= 16 )); then
    DEFAULT_OLLAMA_MODEL="qwen2.5:7b"
  else
    DEFAULT_OLLAMA_MODEL="llama3.2:3b"
  fi
  if [[ "$INSTALL_AI" -eq 1 ]]; then
    OLLAMA_MODEL="$(ask "Modelo Ollama [${DEFAULT_OLLAMA_MODEL}]: " "$DEFAULT_OLLAMA_MODEL")"
  else
    OLLAMA_MODEL="$DEFAULT_OLLAMA_MODEL"
  fi
fi
[[ "$OLLAMA_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "OLLAMA_MODEL invalido."

[[ -n "$REPO_URL" ]] || die "REPO_URL no puede estar vacio."
[[ "$REPO_BRANCH" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] || die "REPO_BRANCH invalido."

if [[ "$INTERACTIVE" -eq 1 ]]; then
  MODE_LABEL="publico"
  [[ "$IS_LOCAL" -eq 1 ]] && MODE_LABEL="local"
  AI_LABEL="no"
  [[ "$INSTALL_AI" -eq 1 ]] && AI_LABEL="si (${OLLAMA_MODEL})"
  printf '\nResumen de instalacion:\n'
  printf '  Repositorio:   %s (%s)\n' "$REPO_URL" "$REPO_BRANCH"
  printf '  Dominio:       %s (%s)\n' "$DOMAIN" "$MODE_LABEL"
  printf '  Admin:         %s\n' "$ADMIN_EMAIL"
  if [[ -n "$ADMIN_PASSWORD" ]]; then
    printf '  Password:      definida por el usuario\n'
  else
    printf '  Password:      gestionada por el instalador\n'
  fi
  if [[ -n "$GOOGLE_CLIENT_ID" && -n "$GOOGLE_CLIENT_SECRET" ]]; then
    printf '  YouTube OAuth: configurado\n'
  else
    printf '  YouTube OAuth: pendiente\n'
  fi
  printf '  IA local:      %s\n' "$AI_LABEL"
  CONFIRM_ANSWER="$(ask "Continuar con la instalacion? [S/n]: " "S")"
  case "${CONFIRM_ANSWER,,}" in
    n|no)
      printf 'Instalacion cancelada.\n'
      exit 0
      ;;
  esac
fi

export DEBIAN_FRONTEND=noninteractive

log "Instalando paquetes del sistema"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install \
  ca-certificates curl gnupg openssl rsync git tar gzip \
  python3 python3-venv python3-dev build-essential libpq-dev pkg-config \
  postgresql postgresql-client postgresql-contrib redis-server redis-tools nginx \
  ufw fail2ban unattended-upgrades certbot iproute2 \
  gpg gpg-agent logrotate openssh-server systemd-timesyncd

if systemctl is-active --quiet apache2 2>/dev/null; then
  systemctl disable --now apache2 || true
fi

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
  || die "Se requiere Python 3.10 o superior."

if [[ "$FORCE_CLONE" -eq 0 && "$USE_LOCAL_REPO" -eq 1 && -n "$REPO_DIR" && -f "$REPO_DIR/requirements.txt" && -f "$REPO_DIR/app/main.py" ]]; then
  log "Usando repositorio local ${REPO_DIR} (usa --force-clone para descargar desde ${REPO_URL})"
else
  log "Descargando repositorio ${REPO_URL} (${REPO_BRANCH})"
  CLONE_DIR="$(mktemp -d)"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$REPO_BRANCH" -- "$REPO_URL" "$CLONE_DIR/repo"
  REPO_DIR="$CLONE_DIR/repo"
fi
[[ -f "$REPO_DIR/requirements.txt" ]] || die "El repositorio no contiene requirements.txt."
REPO_COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"

log "Creando usuario y directorios"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$APP_DIR/logs"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$APP_DIR/media"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$APP_DIR/static"
install -d -m 0700 /etc/huntalgnet

log "Desplegando aplicacion en ${APP_DIR}"
if [[ "$REPO_DIR" != "$APP_DIR" ]]; then
  rsync -a --delete \
    --exclude '.git' --exclude '.env' --exclude 'venv' --exclude '__pycache__' \
    --exclude '.pytest_cache' --exclude 'logs' --exclude 'media' --exclude 'static' \
    --exclude 'celerybeat-schedule' \
    "$REPO_DIR/" "$APP_DIR/"
fi

log "Creando entorno virtual e instalando dependencias Python"
if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
PIP_NO_CACHE_DIR=1 "$APP_DIR/venv/bin/pip" install --upgrade pip wheel
PIP_NO_CACHE_DIR=1 "$APP_DIR/venv/bin/pip" install --disable-pip-version-check -r "$APP_DIR/requirements.txt"

read_env() {
  local key="$1" file="${2:-$ENV_FILE}" value
  [[ -f "$file" ]] || return 0
  value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

set_env() {
  local key="$1" value="$2" escaped
  escaped="${value//\\/\\\\}"
  escaped="${escaped//&/\\&}"
  escaped="${escaped//|/\\|}"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

if [[ -f "$ENV_FILE" ]]; then
  DB_NAME="$(read_env DB_NAME)"
  DB_USER="$(read_env DB_USER)"
  DB_PASSWORD="$(read_env DB_PASSWORD)"
  SECRET_KEY="$(read_env SECRET_KEY)"
  FERNET_KEY="$(read_env FERNET_KEY)"
  REDIS_PASSWORD="$(read_env REDIS_PASSWORD)"
  [[ -n "$DB_NAME" && -n "$DB_USER" && -n "$DB_PASSWORD" ]] \
    || die "El .env existente esta incompleto (DB_NAME/DB_USER/DB_PASSWORD)."
  [[ -n "$SECRET_KEY" && -n "$FERNET_KEY" ]] \
    || die "El .env existente esta incompleto (SECRET_KEY/FERNET_KEY)."
  if [[ -z "$REDIS_PASSWORD" ]]; then
    REDIS_PASSWORD="$(openssl rand -hex 32)"
  fi
else
  DB_NAME="huntalgnet"
  DB_USER="huntalgnet"
  DB_PASSWORD="$(openssl rand -hex 32)"
  SECRET_KEY="$(openssl rand -hex 64)"
  FERNET_KEY="$("$APP_DIR/venv/bin/python" -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
  REDIS_PASSWORD="$(openssl rand -hex 32)"
fi

[[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_NAME invalido."
[[ "$DB_USER" =~ ^[a-z_][a-z0-9_]*$ ]] || die "DB_USER invalido."
[[ "$DB_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || die "DB_PASSWORD contiene caracteres inseguros."
[[ "$REDIS_PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]] || die "REDIS_PASSWORD contiene caracteres inseguros."
if (( ${#SECRET_KEY} < 32 )); then
  warn "SECRET_KEY es corta; considera regenerarla."
fi

[[ "$OLLAMA_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "OLLAMA_MODEL invalido."
[[ "$ADMIN_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "ADMIN_EMAIL invalido."

if [[ -z "$ADMIN_PASSWORD" && -f "$ADMIN_CRED_FILE" ]]; then
  ADMIN_PASSWORD="$(read_env ADMIN_PASSWORD "$ADMIN_CRED_FILE")"
fi
if [[ -z "$ADMIN_PASSWORD" ]]; then
  ADMIN_PASSWORD="$(openssl rand -hex 24)"
fi
if (( ${#ADMIN_PASSWORD} < 8 )); then
  die "ADMIN_PASSWORD debe tener al menos 8 caracteres."
fi
if [[ "$ADMIN_PASSWORD" == *"'"* || "$ADMIN_PASSWORD" == *$'\n'* ]]; then
  die "ADMIN_PASSWORD no puede contener comillas simples ni saltos de linea."
fi

if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
APP_NAME=HuntAlgNet
ENVIRONMENT=production
API_PREFIX=/api/v1
DEBUG=false
ENABLE_DOCS=false
TRUSTED_HOSTS=${DOMAIN},localhost,127.0.0.1
SECRET_KEY=${SECRET_KEY}
ACCESS_TOKEN_EXPIRE_MINUTES=1440
OAUTH_STATE_EXPIRE_MINUTES=15
FERNET_KEY=${FERNET_KEY}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DATABASE_URL=postgresql+psycopg://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=redis://:${REDIS_PASSWORD}@127.0.0.1:6379/0
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_REDIRECT_URI=https://${DOMAIN}/api/v1/integrations/youtube/callback
YOUTUBE_SCOPES="${YOUTUBE_SCOPES}"
FRONTEND_URL=https://${DOMAIN}
CORS_ORIGINS=https://${DOMAIN}
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=${OLLAMA_MODEL}
EOF
else
  set_env ENABLE_DOCS "false"
  set_env TRUSTED_HOSTS "${DOMAIN},localhost,127.0.0.1"
  set_env DB_NAME "$DB_NAME"
  set_env DB_USER "$DB_USER"
  set_env DB_PASSWORD "$DB_PASSWORD"
  set_env DATABASE_URL "postgresql+psycopg://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}"
  set_env REDIS_PASSWORD "$REDIS_PASSWORD"
  set_env REDIS_URL "redis://:${REDIS_PASSWORD}@127.0.0.1:6379/0"
  set_env GOOGLE_REDIRECT_URI "https://${DOMAIN}/api/v1/integrations/youtube/callback"
  set_env FRONTEND_URL "https://${DOMAIN}"
  set_env CORS_ORIGINS "https://${DOMAIN}"
  set_env OLLAMA_BASE_URL "http://127.0.0.1:11434"
  set_env OLLAMA_MODEL "$OLLAMA_MODEL"
  if [[ -n "$GOOGLE_CLIENT_ID" ]]; then
    set_env GOOGLE_CLIENT_ID "$GOOGLE_CLIENT_ID"
  fi
  if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
    set_env GOOGLE_CLIENT_SECRET "$GOOGLE_CLIENT_SECRET"
  fi
fi

chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chown root:"$APP_USER" "$ENV_FILE"
chmod 640 "$ENV_FILE"
chmod 750 "$APP_DIR/deploy/install.sh" "$APP_DIR/deploy/update.sh" "$APP_DIR/deploy/backup.sh"

log "Validando los 10 catalogos de idioma"
runuser -u "$APP_USER" -- bash -c "cd '${APP_DIR}' && venv/bin/python -m app.cli check-i18n"

log "Configurando PostgreSQL"
systemctl enable --now postgresql
for _ in {1..30}; do
  runuser -u postgres -- psql -tAc "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done

PG_CONF_DIR="$(find /etc/postgresql -maxdepth 2 -name postgresql.conf -printf '%h\n' 2>/dev/null | head -n1 || true)"
[[ -n "$PG_CONF_DIR" ]] || die "No se encontro la configuracion de PostgreSQL."

runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET password_encryption = 'scram-sha-256';" >/dev/null
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "SELECT pg_reload_conf();" >/dev/null

HBA_FILE="${PG_CONF_DIR}/pg_hba.conf"
if ! grep -q "huntalgnet-${DB_USER}-ipv4" "$HBA_FILE"; then
  sed -i "1i host all ${DB_USER} 127.0.0.1/32 scram-sha-256 # huntalgnet-${DB_USER}-ipv4" "$HBA_FILE"
fi
if ! grep -q "huntalgnet-${DB_USER}-ipv6" "$HBA_FILE"; then
  sed -i "1i host all ${DB_USER} ::1/128 scram-sha-256 # huntalgnet-${DB_USER}-ipv6" "$HBA_FILE"
fi
chown postgres:postgres "$HBA_FILE"
chmod 640 "$HBA_FILE"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "SELECT pg_reload_conf();" >/dev/null

if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '${DB_PASSWORD}';"
fi
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER ROLE ${DB_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD '${DB_PASSWORD}';"

if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  runuser -u postgres -- createdb -O "${DB_USER}" "${DB_NAME}"
else
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};"
fi

PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null

log "Configurando Redis"
REDIS_CONF="/etc/redis/redis.conf"
[[ -f "$REDIS_CONF" ]] || die "No se encontro ${REDIS_CONF}."
sed -i -E 's|^bind .*|bind 127.0.0.1 -::1|' "$REDIS_CONF"
grep -q '^bind ' "$REDIS_CONF" || printf 'bind 127.0.0.1 -::1\n' >> "$REDIS_CONF"
sed -i -E 's|^protected-mode .*|protected-mode yes|' "$REDIS_CONF"
grep -q '^protected-mode ' "$REDIS_CONF" || printf 'protected-mode yes\n' >> "$REDIS_CONF"
if grep -q '^requirepass ' "$REDIS_CONF"; then
  sed -i "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" "$REDIS_CONF"
else
  printf 'requirepass %s\n' "$REDIS_PASSWORD" >> "$REDIS_CONF"
fi
for command in FLUSHALL FLUSHDB DEBUG; do
  grep -q "^rename-command ${command} " "$REDIS_CONF" \
    || printf 'rename-command %s ""\n' "$command" >> "$REDIS_CONF"
done
chown redis:redis "$REDIS_CONF"
chmod 640 "$REDIS_CONF"
systemctl enable --now redis-server
systemctl restart redis-server
for _ in {1..30}; do
  redis-cli -h 127.0.0.1 --no-auth-warning -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG && break
  sleep 1
done
redis-cli -h 127.0.0.1 --no-auth-warning -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG \
  || die "Redis no responde con la contrasena configurada."

log "Aplicando migraciones"
runuser -u "$APP_USER" -- bash -c "cd '${APP_DIR}' && venv/bin/alembic upgrade head"

log "Creando superadministrador"
runuser -u "$APP_USER" -- bash -c "cd '${APP_DIR}' && venv/bin/python -m app.cli create-superadmin --email '${ADMIN_EMAIL}' --password '${ADMIN_PASSWORD}' --name 'Administrator'"

{
  printf 'URL=https://%s\n' "$DOMAIN"
  printf 'ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL"
  printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
} > "$ADMIN_CRED_FILE"
chmod 600 "$ADMIN_CRED_FILE"

log "Instalando servicios systemd"
install -m 644 "$APP_DIR/deploy/systemd/huntalgnet-api.service" /etc/systemd/system/huntalgnet-api.service
install -m 644 "$APP_DIR/deploy/systemd/huntalgnet-worker.service" /etc/systemd/system/huntalgnet-worker.service
install -m 644 "$APP_DIR/deploy/systemd/huntalgnet-beat.service" /etc/systemd/system/huntalgnet-beat.service
install -m 644 "$APP_DIR/deploy/systemd/huntalgnet-backup.service" /etc/systemd/system/huntalgnet-backup.service
install -m 644 "$APP_DIR/deploy/systemd/huntalgnet-backup.timer" /etc/systemd/system/huntalgnet-backup.timer
systemctl daemon-reload
if ! systemctl enable --now huntalgnet-api; then
  journalctl -u huntalgnet-api -n 40 --no-pager >&2 || true
  die "La API no arranco."
fi
systemctl enable --now huntalgnet-worker || warn "El worker no arranco; revisa journalctl -u huntalgnet-worker."
systemctl enable --now huntalgnet-beat || warn "El beat no arranco; revisa journalctl -u huntalgnet-beat."

log "Esperando a la API"
API_OK=0
for _ in {1..40}; do
  if curl -fsS http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then
    API_OK=1
    break
  fi
  sleep 1
done
if [[ "$API_OK" -ne 1 ]]; then
  journalctl -u huntalgnet-api -n 40 --no-pager >&2 || true
  die "La API no responde."
fi

log "Configurando Nginx y TLS"
install -d -m 0755 /etc/nginx/snippets /etc/nginx/conf.d
install -d -m 0755 "$ACME_ROOT/.well-known/acme-challenge"
install -d -m 0750 "$SSL_DIR"

cat > /etc/nginx/snippets/huntalgnet-proxy.conf <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_hide_header Server;
proxy_hide_header X-Powered-By;
proxy_read_timeout 300s;
proxy_send_timeout 300s;
EOF

cat > /etc/nginx/conf.d/huntalgnet-limits.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=huntalgnet_api:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=huntalgnet_auth:10m rate=3r/m;
limit_req_status 429;
limit_conn_zone $binary_remote_addr zone=huntalgnet_conn:10m;
limit_conn_status 429;
EOF
chmod 644 /etc/nginx/snippets/huntalgnet-proxy.conf /etc/nginx/conf.d/huntalgnet-limits.conf

cat > /etc/nginx/sites-available/huntalgnet <<EOF
server {
    listen ${HTTP_LISTEN};
    listen ${HTTP_LISTEN6};
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        include /etc/nginx/snippets/huntalgnet-proxy.conf;
    }
}
EOF
chmod 644 /etc/nginx/sites-available/huntalgnet
ln -sf /etc/nginx/sites-available/huntalgnet /etc/nginx/sites-enabled/huntalgnet
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

TLS_MODE="selfsigned"
if [[ "$IS_IP" -eq 0 && "$IS_LOCAL" -eq 0 ]]; then
  CERTBOT_ARGS=(certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --keep-until-expiring --deploy-hook "systemctl reload nginx")
  if [[ -n "$EMAIL" ]]; then
    CERTBOT_ARGS+=(-m "$EMAIL")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi
  if (umask 022; certbot "${CERTBOT_ARGS[@]}"); then
    TLS_MODE="letsencrypt"
  else
    warn "Let's Encrypt no pudo emitir el certificado; se usara TLS autofirmado."
  fi
fi

if [[ "$TLS_MODE" == "letsencrypt" ]]; then
  SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
  systemctl enable --now certbot.timer 2>/dev/null || true
else
  SSL_CERT="${SSL_DIR}/huntalgnet.crt"
  SSL_KEY="${SSL_DIR}/huntalgnet.key"
  NEED_CERT=1
  if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    if [[ "$IS_IP" -eq 1 ]]; then
      openssl x509 -in "$SSL_CERT" -noout -checkip "$DOMAIN" >/dev/null 2>&1 && NEED_CERT=0 || NEED_CERT=1
    else
      openssl x509 -in "$SSL_CERT" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 && NEED_CERT=0 || NEED_CERT=1
    fi
  fi
  if [[ "$NEED_CERT" -eq 1 ]]; then
    SAN="DNS:${DOMAIN}"
    [[ "$IS_IP" -eq 1 ]] && SAN="IP:${DOMAIN}"
    openssl req -x509 -nodes -newkey rsa:4096 -sha256 -days 3650 \
      -keyout "$SSL_KEY" -out "$SSL_CERT" \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=${SAN},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
    chmod 600 "$SSL_KEY"
    chmod 644 "$SSL_CERT"
  fi
fi

sed -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__SSL_CERT__|${SSL_CERT}|g" \
    -e "s|__SSL_KEY__|${SSL_KEY}|g" \
    -e "s|__ACME_ROOT__|${ACME_ROOT}|g" \
    -e "s|__HTTP_LISTEN__|${HTTP_LISTEN}|g" \
    -e "s|__HTTP_LISTEN6__|${HTTP_LISTEN6}|g" \
    -e "s|__HTTPS_LISTEN__|${HTTPS_LISTEN}|g" \
    -e "s|__HTTPS_LISTEN6__|${HTTPS_LISTEN6}|g" \
    "$APP_DIR/deploy/nginx/huntalgnet.conf" > /etc/nginx/sites-available/huntalgnet
chmod 644 /etc/nginx/sites-available/huntalgnet
nginx -t
systemctl reload nginx

if [[ "$INSTALL_AI" -eq 1 ]]; then
  log "Instalando Ollama y modelo local"
  if ! command -v ollama >/dev/null 2>&1; then
    OLLAMA_SCRIPT="$(mktemp)"
    if curl -fsSL https://ollama.com/install.sh -o "$OLLAMA_SCRIPT"; then
      if [[ -n "$OLLAMA_INSTALL_SHA256" ]]; then
        if ! printf '%s  %s\n' "$OLLAMA_INSTALL_SHA256" "$OLLAMA_SCRIPT" | sha256sum -c - >/dev/null; then
          rm -f "$OLLAMA_SCRIPT"
          die "Checksum del instalador de Ollama invalido."
        fi
      fi
      if ! OLLAMA_VERSION="$OLLAMA_VERSION" sh "$OLLAMA_SCRIPT"; then
        warn "Ollama no se pudo instalar."
      fi
    else
      warn "No se pudo descargar el instalador de Ollama."
    fi
    rm -f "$OLLAMA_SCRIPT"
  fi

  if command -v ollama >/dev/null 2>&1; then
    install -d -m 0755 /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/huntalgnet.conf <<EOF
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_ORIGINS=http://127.0.0.1,https://${DOMAIN}"
EOF
    chmod 644 /etc/systemd/system/ollama.service.d/huntalgnet.conf
    systemctl daemon-reload
    systemctl enable --now ollama || warn "Ollama no arranco."
    for _ in {1..30}; do
      curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
      sleep 2
    done
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      if ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$OLLAMA_MODEL"; then
        ollama pull "$OLLAMA_MODEL" || warn "No se pudo descargar el modelo ${OLLAMA_MODEL}."
      fi
    else
      warn "Ollama no responde en 127.0.0.1:11434."
    fi
  fi
else
  log "IA local omitida (INSTALL_AI=0)"
fi

if [[ "$ENABLE_FIREWALL" -eq 1 ]]; then
  log "Configurando firewall UFW"
  ufw default deny incoming
  ufw default allow outgoing
  if [[ "$IS_LOCAL" -eq 1 ]]; then
    ufw allow in on lo
  else
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
  SSH_PORTS="$(sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -u || true)"
  if command -v ss >/dev/null 2>&1; then
    SS_PORTS="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | sed 's/.*://' | sort -u || true)"
    SSH_PORTS="${SSH_PORTS} ${SS_PORTS}"
  fi
  if [[ -z "${SSH_PORTS// /}" ]]; then
    SSH_PORTS="22"
  fi
  for port in $SSH_PORTS; do
    [[ "$port" =~ ^[0-9]+$ ]] && ufw allow "${port}/tcp"
  done
  ufw --force enable
fi

if [[ "$ENABLE_FAIL2BAN" -eq 1 ]]; then
  log "Configurando fail2ban"
  cat > /etc/fail2ban/filter.d/nginx-req-limit.conf <<'EOF'
[Definition]
failregex = limiting requests, excess:.* by zone .*, client: <HOST>
ignoreregex =
EOF
  cat > /etc/fail2ban/jail.d/huntalgnet.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
backend = systemd

[nginx-http-auth]
enabled = true

[nginx-req-limit]
enabled = true
filter = nginx-req-limit
logpath = /var/log/nginx/error.log
maxretry = 5
findtime = 60
bantime = 3600
EOF
  chmod 644 /etc/fail2ban/filter.d/nginx-req-limit.conf /etc/fail2ban/jail.d/huntalgnet.local
  systemctl enable --now fail2ban
  systemctl restart fail2ban
fi

systemctl enable --now systemd-timesyncd 2>/dev/null || true

if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || warn "No se pudo activar SSH."
fi

log "Activando actualizaciones de seguridad automaticas"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
chmod 644 /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades 2>/dev/null || true

if [[ "$HARDEN_SYSCTL" -eq 1 ]]; then
  log "Aplicando hardening del kernel"
  cat > /etc/sysctl.d/99-huntalgnet.conf <<'EOF'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
  chmod 644 /etc/sysctl.d/99-huntalgnet.conf
  sysctl --system >/dev/null 2>&1 || warn "No se pudieron aplicar todos los parametros sysctl."
fi

install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/huntalgnet.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=1G
EOF
chmod 644 /etc/systemd/journald.conf.d/huntalgnet.conf
systemctl restart systemd-journald 2>/dev/null || true

log "Configurando rotacion de logs"
cat > /etc/logrotate.d/huntalgnet <<'EOF'
/opt/huntalgnet/logs/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su huntalgnet huntalgnet
}
EOF
chmod 644 /etc/logrotate.d/huntalgnet
systemctl enable --now logrotate.timer 2>/dev/null || true

if [[ "$HARDEN_SSH" -eq 1 ]]; then
  log "Endureciendo SSH"
  SSH_BACKUP="/etc/ssh/sshd_config.bak.$(date +%s)"
  cp /etc/ssh/sshd_config "$SSH_BACKUP"
  sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  grep -q '^PermitRootLogin ' /etc/ssh/sshd_config \
    || printf 'PermitRootLogin prohibit-password\n' >> /etc/ssh/sshd_config
  if ! sshd -t; then
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    die "Configuracion SSH invalida; se restauro la copia."
  fi
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
fi

log "Configurando backups cifrados"
if [[ ! -f "$BACKUP_KEY_FILE" ]]; then
  printf '%s' "$(openssl rand -hex 32)" > "$BACKUP_KEY_FILE"
fi
chmod 600 "$BACKUP_KEY_FILE"
install -d -m 0700 "$BACKUP_DIR"
systemctl daemon-reload
systemctl enable --now huntalgnet-backup.timer

log "Verificando dependencias del sistema"
REQUIRED_COMMANDS=(python3 curl openssl rsync git tar gzip psql redis-cli nginx certbot gpg logrotate ufw fail2ban-client)
for command_name in "${REQUIRED_COMMANDS[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || die "Falta el comando requerido: ${command_name}"
done
if [[ "$INSTALL_AI" -eq 1 ]]; then
  command -v ollama >/dev/null 2>&1 || warn "Ollama no esta disponible; la IA local no funcionara."
fi
for service_name in postgresql redis-server nginx; do
  systemctl is-active --quiet "$service_name" || die "El servicio ${service_name} no esta activo."
done

log "Verificando el despliegue"
curl -fsS http://127.0.0.1:8000/api/v1/health >/dev/null || die "La API no responde."
if [[ "$IS_IP" -eq 1 ]]; then
  curl -k -fsS -H "Host: ${DOMAIN}" "https://127.0.0.1/api/v1/health" >/dev/null \
    || die "Nginx no responde por HTTPS."
else
  curl -k -fsS --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/api/v1/health" >/dev/null \
    || die "Nginx no responde por HTTPS."
fi

if [[ "$IS_LOCAL" -eq 1 ]]; then
  warn "Modo local: la aplicacion solo escucha en loopback (127.0.0.1). Para publicarla, reejecuta con DOMAIN=tudominio.com."
elif [[ "$IS_IP" -eq 1 || "$TLS_MODE" != "letsencrypt" ]]; then
  warn "TLS no es de confianza publica. Configura un dominio con DNS y vuelve a ejecutar para Let's Encrypt."
fi
if [[ -z "$GOOGLE_CLIENT_ID" || -z "$GOOGLE_CLIENT_SECRET" ]]; then
  warn "YouTube OAuth no configurado. Anade GOOGLE_CLIENT_ID y GOOGLE_CLIENT_SECRET en ${ENV_FILE} y reinicia huntalgnet-api."
fi

MODE_LABEL="publico"
[[ "$IS_LOCAL" -eq 1 ]] && MODE_LABEL="local"
AI_OUTPUT="${OLLAMA_MODEL} (127.0.0.1:11434)"
[[ "$INSTALL_AI" -ne 1 ]] && AI_OUTPUT="no instalada"

cat <<EOF

Instalacion completada.

URL:              https://${DOMAIN}
Modo:             ${MODE_LABEL}
Repositorio:      ${REPO_URL} (${REPO_BRANCH}${REPO_COMMIT:+, ${REPO_COMMIT}})
Admin:            ${ADMIN_EMAIL}
Credenciales:     ${ADMIN_CRED_FILE}
Backup cifrado:   ${BACKUP_DIR} (clave en ${BACKUP_KEY_FILE})
IA local:         ${AI_OUTPUT}
TLS:              ${TLS_MODE}

Servicios:
  systemctl status huntalgnet-api huntalgnet-worker huntalgnet-beat
  journalctl -u huntalgnet-api -f

Descifrar un backup:
  gpg --batch --decrypt --passphrase-file ${BACKUP_KEY_FILE} archivo.dump.gpg > backup.dump

Idiomas: en-US, es-ES, fr-FR, it-IT, de-DE, zh-CN, ja-JP, pt-PT, ar-SA, ru-RU

EOF
