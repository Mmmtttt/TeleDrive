# TeleDrive Demo

This demo reads the local Teldrive Postgres database, discovers uploaded image/video files, and serves a small gallery at:

```text
http://127.0.0.1:8890
```

Start:

```powershell
cd D:\code\TeleDrive\run\demo
.\start.ps1
```

Stop:

```powershell
.\stop.ps1
```

The browser never receives the Teldrive session hash. Media is proxied through:

```text
/media/<file_id>/<filename>
```

The proxy preserves `Range` headers, so videos uploaded to Teldrive should play through the same page once they appear in the database.
