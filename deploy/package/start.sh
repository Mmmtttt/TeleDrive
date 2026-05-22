#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

new_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '='
  fi
}

package_version() {
  if [ -f VERSION ]; then
    tr -d '\r\n' < VERSION
  else
    printf '%s' "local"
  fi
}

write_default_env() {
  VERSION_VALUE=$(package_version)
  POSTGRES_PASSWORD_VALUE=$(new_secret)
  JWT_SECRET_VALUE=$(new_secret)
  BRIDGE_TOKEN_VALUE=$(new_secret)
  cat > .env <<EOF
TELEDRIVE_VERSION=$VERSION_VALUE
POSTGRES_IMAGE=ghcr.io/tgdrive/postgres:17-alpine
TELDRIVE_IMAGE=ghcr.io/tgdrive/teldrive:latest
POSTGRES_USER=teldrive
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_VALUE
POSTGRES_DB=postgres
TELDRIVE_PORT=8787
IMPORTER_PORT=8891
BRIDGE_PORT=8892
BRIDGE_TOKEN=$BRIDGE_TOKEN_VALUE
DEFAULT_LIMIT=100
POLL_INTERVAL_SECONDS=0
IMPORT_FOLDER=Telegram Imports
CATALOG_LIMIT=100
TG_APP_ID=2496
TG_APP_HASH=8da85b0d5bfe62527e5b244c209159c3
JWT_SECRET=$JWT_SECRET_VALUE
EOF
}

env_value() {
  key=$1
  fallback=$2
  value=$(grep -E "^$key=" .env | tail -n 1 | sed "s/^$key=//" || true)
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

write_config() {
  [ -f config.template.toml ] || {
    echo "Missing config.template.toml" >&2
    exit 1
  }
  POSTGRES_PASSWORD_VALUE=$(env_value POSTGRES_PASSWORD change-me)
  JWT_SECRET_VALUE=$(env_value JWT_SECRET "$(new_secret)")
  TG_APP_ID_VALUE=$(env_value TG_APP_ID 2496)
  TG_APP_HASH_VALUE=$(env_value TG_APP_HASH 8da85b0d5bfe62527e5b244c209159c3)
  sed \
    -e "s|{{POSTGRES_PASSWORD}}|$POSTGRES_PASSWORD_VALUE|g" \
    -e "s|{{JWT_SECRET}}|$JWT_SECRET_VALUE|g" \
    -e "s|{{TG_APP_ID}}|$TG_APP_ID_VALUE|g" \
    -e "s|{{TG_APP_HASH}}|$TG_APP_HASH_VALUE|g" \
    config.template.toml > config.toml
}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to run the full offline TeleDrive stack." >&2
  exit 1
fi

[ -f .env ] || write_default_env
[ -f config.toml ] || write_config

if [ "${1:-}" != "--no-load-images" ] && [ -d images ]; then
  for image in images/*.tar; do
    [ -f "$image" ] || continue
    echo "Loading image $(basename "$image")"
    docker load --input "$image"
  done
fi

docker compose --env-file .env -f docker-compose.yml up -d

echo ""
echo "TeleDrive is starting."
echo "Teldrive: http://127.0.0.1:$(env_value TELDRIVE_PORT 8787)"
echo "Importer: http://127.0.0.1:$(env_value IMPORTER_PORT 8891)"
echo "Bridge:   http://127.0.0.1:$(env_value BRIDGE_PORT 8892)"
