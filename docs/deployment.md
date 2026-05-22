# Deployment

This project follows the same release idea as ULTIMATE_WEB: build once in GitHub Actions, publish versioned artifacts, and deploy from the artifact instead of rebuilding on the target machine.

## Deployment Profiles

| Profile | Artifact | Runtime | Use case |
| --- | --- | --- | --- |
| Windows full stack | `teledrive-windows-amd64-<version>.zip` | Docker Desktop or compatible Docker engine | Local Windows server, development workstation, lightweight NAS |
| Linux full stack | `teledrive-linux-amd64-<version>.tar.gz` | Docker Engine or compatible runtime | VPS, NAS, home server |
| Docker offline | `teledrive-docker-offline-<version>.tar.gz` | Docker Engine or compatible runtime | Server deployment where native host binaries are not needed |
| Native lite | `bin/teledrive-importer`, `bin/teledrive-bridge` | No Go runtime needed | Advanced setup where Teldrive/PostgreSQL already run elsewhere |

The full stack packages bundle container images as `.tar` files. That makes deployment independent of Go, Node.js, PostgreSQL installers, and network access to GHCR. A container runtime is still the boundary dependency for the full stack.

## First Start

Windows:

```powershell
Expand-Archive .\teledrive-windows-amd64-0.1.0.zip
cd .\teledrive-windows-amd64-0.1.0
.\start.ps1
```

Linux:

```sh
tar -xzf teledrive-linux-amd64-0.1.0.tar.gz -C teledrive
cd teledrive
chmod +x start.sh stop.sh
./start.sh
```

The start script:

1. Creates `.env` if it does not exist.
2. Generates strong local `POSTGRES_PASSWORD`, `JWT_SECRET`, and `BRIDGE_TOKEN`.
3. Generates `config.toml` from `config.template.toml`.
4. Loads bundled Docker images from `images/*.tar`.
5. Starts `postgres`, `teldrive`, `importer`, and `bridge`.

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

## GitHub Release Workflow

Push a version tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow `.github/workflows/release.yml` builds:

- Windows amd64 native binaries.
- Linux amd64 native binaries.
- Docker images for importer and bridge.
- Offline image archives for Postgres, Teldrive, importer, and bridge.
- Final release archives.

## Native Full Stack Note

A true no-Docker full stack would need bundled PostgreSQL native binaries for every target OS, plus service registration and data directory lifecycle management. That can be added later as a `native-full` profile, but the MVP release line uses offline Docker images because it is reproducible and much safer for Telegram/Teldrive session storage.
