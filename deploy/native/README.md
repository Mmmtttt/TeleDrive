# TeleDrive Native Runtime

This package is the no-Docker runtime shape for TeleDrive.

Expected package layout:

```text
bin/
  teldrive
  teledrive-importer
  teledrive-bridge
  teledrive-launcher
runtime/
  postgres/
config/
  config.template.toml
data/
logs/
```

Run:

```powershell
.\start.ps1
```

```sh
./start.sh
```

The launcher initializes the bundled PostgreSQL runtime, generates local secrets, starts Teldrive, starts the importer and Bridge, then opens Teldrive in the browser.

Native packages intentionally use a Teldrive build with PGroonga search downgraded to portable PostgreSQL search behavior. Docker packages keep the upstream PGroonga-enabled runtime.
