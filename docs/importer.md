# Teldrive Importer

Small MVP importer for media that was manually forwarded into the Telegram channel used by Teldrive.

## Trigger

Manual trigger:

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8891/api/import -ContentType "application/json" -Body '{"limit":100,"convert_photos":true}'
```

Preview without writing anything:

```powershell
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8891/api/import -ContentType "application/json" -Body '{"limit":100,"convert_photos":true,"dry_run":true}'
```

Optional polling:

Set `POLL_INTERVAL_SECONDS` on the compose service. Keep it `0` for manual-only mode.

## Behavior

- Existing Telegram document/video messages are imported by registering their message id into `teldrive.files.parts`.
- Telegram photo messages are downloaded and re-uploaded to the same channel as document files, then registered.
- Imported files are placed in `/root/Telegram Imports`.
- The importer keeps its own marker table at `teldrive_importer.imported_messages` so repeated runs are idempotent.

## API

- `GET /health` returns service health.
- `GET /api/status` returns the last import result.
- `POST /api/import` runs one import pass.

Request fields:

- `limit`: number of recent channel messages to scan. Defaults to `100`.
- `convert_photos`: when true, normal Telegram photo messages are re-uploaded as document files.
- `dry_run`: when true, scans and reports without creating DB rows or uploading converted photos.
- `user_id` and `channel_id`: optional overrides. By default the importer uses the latest Teldrive session and selected channel.
