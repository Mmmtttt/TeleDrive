#!/usr/bin/env sh
set -eu

VERSION=${VERSION:-local}
TARGET=${TARGET:-linux}
ARCH=${ARCH:-amd64}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STAGE="$ROOT/dist/teledrive-$TARGET-$ARCH"
BIN="$STAGE/bin"

rm -rf "$STAGE"
mkdir -p "$BIN"

EXT=""
if [ "$TARGET" = "windows" ]; then
  EXT=".exe"
fi

CGO_ENABLED=0 GOOS="$TARGET" GOARCH="$ARCH" go build -trimpath -ldflags="-s -w" -o "$BIN/teledrive-importer$EXT" "$ROOT/cmd/teledrive-importer"
CGO_ENABLED=0 GOOS="$TARGET" GOARCH="$ARCH" go build -trimpath -ldflags="-s -w" -o "$BIN/teledrive-bridge$EXT" "$ROOT/cmd/teledrive-bridge"

cp "$ROOT/deploy/docker/docker-compose.yml" "$STAGE/"
cp "$ROOT/deploy/docker/config.template.toml" "$STAGE/"
cp "$ROOT/deploy/docker/.env.example" "$STAGE/"
cp "$ROOT/deploy/package/start.ps1" "$STAGE/"
cp "$ROOT/deploy/package/stop.ps1" "$STAGE/"
cp "$ROOT/deploy/package/start.sh" "$STAGE/"
cp "$ROOT/deploy/package/stop.sh" "$STAGE/"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"
chmod +x "$STAGE/start.sh" "$STAGE/stop.sh"

if [ "${INCLUDE_DOCKER_IMAGES:-0}" = "1" ]; then
  mkdir -p "$STAGE/images"
  docker build --target importer -t "teledrive-importer:$VERSION" "$ROOT"
  docker build --target bridge -t "teledrive-bridge:$VERSION" "$ROOT"
  docker pull ghcr.io/tgdrive/teldrive:latest
  docker pull ghcr.io/tgdrive/postgres:17-alpine
  docker save -o "$STAGE/images/teledrive-importer.tar" "teledrive-importer:$VERSION"
  docker save -o "$STAGE/images/teledrive-bridge.tar" "teledrive-bridge:$VERSION"
  docker save -o "$STAGE/images/teldrive.tar" ghcr.io/tgdrive/teldrive:latest
  docker save -o "$STAGE/images/postgres.tar" ghcr.io/tgdrive/postgres:17-alpine
fi

ARCHIVE="$ROOT/dist/teledrive-$TARGET-$ARCH-$VERSION.tar.gz"
rm -f "$ARCHIVE"
(cd "$STAGE" && tar -czf "$ARCHIVE" .)
echo "Wrote $ARCHIVE"
