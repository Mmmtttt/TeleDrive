# Teldrive MVP Runtime

This folder runs the upstream `tgdrive/teldrive` image with a local Postgres database, the TeleDrive importer, and the TeleDrive Bridge.

```powershell
cd D:\code\TeleDrive\run\teldrive
docker compose up -d
```

Or:

```powershell
.\start.ps1
```

Open `http://127.0.0.1:8787` and log in with Telegram by QR code or phone flow.

The importer is available at `http://127.0.0.1:8891`. It is manual by default:

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8891/api/import -ContentType "application/json" -Body '{"limit":100,"convert_photos":true}'
```

Use `dry_run` first when scanning a large channel:

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8891/api/import -ContentType "application/json" -Body '{"limit":100,"convert_photos":true,"dry_run":true}'
```

The default Telegram app id/hash are Teldrive's upstream desktop-web defaults. For a longer-lived personal setup, replace `tg.app-id` and `tg.app-hash` in `config.toml` with your own Telegram API credentials from `https://my.telegram.org`.

The Bridge is available at `http://127.0.0.1:8892`:

```powershell
Invoke-RestMethod http://127.0.0.1:8892/v1/catalog/items
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8892/v1/imports -ContentType "application/json" -Body '{"limit":100,"convert_photos":true}'
```

To stop it:

```powershell
.\stop.ps1
```
