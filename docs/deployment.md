# Deployment

This project follows the same release idea as ULTIMATE_WEB: build once in GitHub Actions, publish versioned artifacts, and deploy from the artifact instead of rebuilding on the target machine.

## Deployment Profiles

| Profile | Artifact | Runtime | Use case |
| --- | --- | --- | --- |
| Windows native | `teledrive-windows-native-amd64-<version>.zip` | No Docker; bundled PostgreSQL runtime | Local Windows desktop/server |
| Linux native | `teledrive-linux-native-amd64-<version>.tar.gz` | No Docker; bundled PostgreSQL runtime | VPS, NAS, home server |
| Docker offline | `teledrive-docker-offline-<version>.tar.gz` | Docker Engine or compatible runtime | Server deployment where native host binaries are not needed |
| Native lite | `bin/teledrive-importer`, `bin/teledrive-bridge` | No Go runtime needed | Advanced setup where Teldrive/PostgreSQL already run elsewhere |

Native packages bundle `teldrive`, `teledrive-importer`, `teledrive-bridge`, `teledrive-launcher`, and PostgreSQL. Docker offline packages bundle container images as `.tar` files. Both deployment lines are independent of Go, Node.js, PostgreSQL installers, and network access to GHCR; only the Docker line requires a container runtime.

## First Start

Windows:

```powershell
Expand-Archive .\teledrive-windows-native-amd64-0.2.0.zip
cd .\teledrive-windows-native-amd64-0.2.0
.\start.ps1
```

Linux:

```sh
mkdir -p teledrive
tar -xzf teledrive-linux-native-amd64-0.2.0.tar.gz -C teledrive
cd teledrive
chmod +x start.sh stop.sh
./start.sh
```

The native start script delegates to `teledrive-launcher`, which:

1. Initializes the bundled PostgreSQL data directory.
2. Generates strong local database and JWT secrets.
3. Generates `config/config.toml` from `config/config.template.toml`.
4. Starts PostgreSQL, Teldrive, importer, and Bridge.
5. Stops child services when the launcher receives Ctrl+C.

Default ports:

| Service | URL |
| --- | --- |
| Teldrive | `http://127.0.0.1:8787` |
| Importer | `http://127.0.0.1:8891` |
| Bridge | `http://127.0.0.1:8892` |

## Bridge API for ULTIMATE_WEB

ULTIMATE_WEB should only talk to Bridge:

```text
TELEDRIVE_BRIDGE_URL=http://teledrive-bridge:8892
TELEDRIVE_BRIDGE_TOKEN=<BRIDGE_TOKEN from .env>
```

Stable endpoints:

- `GET /v1/catalog/items`
- `GET /v1/files/{file_id}/content?name={filename}`
- `POST /v1/imports`
- `GET /v1/imports/latest`

## Docker Offline Start

```powershell
New-Item -ItemType Directory -Force .\teledrive-docker | Out-Null
tar -xzf .\teledrive-docker-offline-0.2.0.tar.gz -C .\teledrive-docker
cd .\teledrive-docker
.\start.ps1
```

```sh
mkdir -p teledrive-docker
tar -xzf teledrive-docker-offline-0.2.0.tar.gz -C teledrive-docker
cd teledrive-docker
./start.sh
```

The Docker start script:

1. Creates `.env` if it does not exist.
2. Generates strong local `POSTGRES_PASSWORD`, `JWT_SECRET`, and `BRIDGE_TOKEN`.
3. Generates `config.toml` from `config.template.toml`.
4. Loads bundled Docker images from `images/*.tar`.
5. Starts `postgres`, `teldrive`, `importer`, and `bridge`.

## GitHub Release Workflow

Push a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow `.github/workflows/release.yml` builds:

- Windows amd64 native no-Docker package.
- Linux amd64 native no-Docker package.
- Docker images for importer and bridge.
- Offline image archives for Postgres, Teldrive, importer, and bridge.
- Final release archives.

## Native Search Note

Docker packages keep the upstream PGroonga-enabled Teldrive runtime. Native packages apply a build-time compatibility patch that downgrades PGroonga search indexes and operators to portable PostgreSQL behavior. Uploading, importing, image browsing, video streaming, and Bridge media proxying remain the priority path.
