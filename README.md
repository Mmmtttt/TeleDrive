# TeleDrive Bridge

TeleDrive Bridge is a small integration layer around [Teldrive](https://github.com/tgdrive/teldrive). It turns a Telegram channel managed by Teldrive into a backend media source that can be consumed by ULTIMATE_WEB or by a standalone demo.

The current MVP provides:

- `teledrive-importer`: imports forwarded Telegram media messages into Teldrive's managed file table.
- `teledrive-bridge`: exposes a stable media catalog and streaming proxy API, while hiding Teldrive session hashes from browsers and downstream apps.
- Offline Docker packaging templates for Windows, Linux, and server/NAS deployment.

## Architecture

```text
Telegram Channel
  -> Teldrive + PostgreSQL
  -> teledrive-importer
  -> teledrive-bridge
  -> ULTIMATE_WEB / demo / client apps
```

Teldrive remains an upstream subproject pinned under `third_party/teldrive`. TeleDrive-owned code lives under `cmd`, `deploy`, `db`, `docs`, and `scripts`.

## Local MVP

The existing local MVP stack is under `run/teldrive`:

```powershell
.\run\teldrive\start.ps1
```

After login and channel binding in Teldrive:

- Teldrive: <http://127.0.0.1:8787>
- Importer: <http://127.0.0.1:8891>
- Bridge: <http://127.0.0.1:8892>

Trigger an import:

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8892/v1/imports -ContentType "application/json" -Body '{"limit":100,"convert_photos":true}'
```

List media through the Bridge:

```powershell
Invoke-RestMethod http://127.0.0.1:8892/v1/catalog/items
```

## Release Packages

GitHub Actions builds three release artifacts:

- `teledrive-windows-native-amd64-<version>.zip`
- `teledrive-linux-native-amd64-<version>.tar.gz`
- `teledrive-docker-offline-<version>.tar.gz`

The Windows and Linux native archives include `teldrive`, `teledrive-importer`, `teledrive-bridge`, `teledrive-launcher`, and a bundled PostgreSQL runtime. They are intended to run without Docker, Go, Node.js, or a manually installed database.

The Docker offline archive includes all container images used by the full stack:

- `ghcr.io/tgdrive/postgres:17-alpine`
- `ghcr.io/tgdrive/teldrive:latest`
- `teledrive-importer:<version>`
- `teledrive-bridge:<version>`

The full stack is one-command after extraction:

```powershell
.\start.ps1
```

```sh
./start.sh
```

Docker or a compatible container runtime is required only for the Docker offline package. It does not need Go, Node.js, PostgreSQL installers, or internet access at deploy time when the offline image archive is used.

## Build Locally

Windows:

```powershell
.\build\package.ps1 -Version local -Target windows -IncludeDockerImages
```

Linux:

```sh
VERSION=local TARGET=linux INCLUDE_DOCKER_IMAGES=1 ./build/package.sh
```

Native no-Docker packages are built in GitHub Actions because they bundle OS-specific PostgreSQL runtimes.

## Publish

Create an empty GitHub repository, then push this local repo:

```powershell
.\scripts\publish-github.ps1 -RepositoryUrl https://github.com/<owner>/<repo>.git
```

Tag-based releases are built by GitHub Actions:

```powershell
git tag v0.1.0
git push origin v0.1.0
```

## Documentation

- [Architecture](docs/architecture.md)
- [Bridge API](docs/bridge-api.md)
- [Deployment](docs/deployment.md)
- [Importer](docs/importer.md)
- [Database](docs/database.md)
- [Runbook](docs/runbook.md)
- [Teldrive subproject](docs/teldrive-subproject.md)

## License

TeleDrive-owned code is released under the MIT License. Third-party projects keep their upstream licenses.
