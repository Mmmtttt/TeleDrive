param(
  [string]$Version = "local",
  [ValidateSet("windows", "linux")]
  [string]$Target = "windows",
  [string]$Arch = "amd64",
  [switch]$IncludeDockerImages
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Stage = Join-Path $Root "dist\teledrive-$Target-$Arch"
$Bin = Join-Path $Stage "bin"

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Stage
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

$oldGoos = $env:GOOS
$oldGoarch = $env:GOARCH
$oldCgo = $env:CGO_ENABLED
try {
  $env:GOOS = $Target
  $env:GOARCH = $Arch
  $env:CGO_ENABLED = "0"
  $ext = ""
  if ($Target -eq "windows") {
    $ext = ".exe"
  }
  go build -trimpath -ldflags="-s -w" -o (Join-Path $Bin "teledrive-importer$ext") .\cmd\teledrive-importer
  go build -trimpath -ldflags="-s -w" -o (Join-Path $Bin "teledrive-bridge$ext") .\cmd\teledrive-bridge
} finally {
  $env:GOOS = $oldGoos
  $env:GOARCH = $oldGoarch
  $env:CGO_ENABLED = $oldCgo
}

Copy-Item deploy\docker\docker-compose.yml $Stage
Copy-Item deploy\docker\config.template.toml $Stage
Copy-Item deploy\docker\.env.example $Stage
Copy-Item deploy\package\start.ps1 $Stage
Copy-Item deploy\package\stop.ps1 $Stage
Copy-Item deploy\package\start.sh $Stage
Copy-Item deploy\package\stop.sh $Stage
Set-Content -Encoding ASCII -Path (Join-Path $Stage "VERSION") -Value $Version

if ($IncludeDockerImages) {
  $Images = Join-Path $Stage "images"
  New-Item -ItemType Directory -Force -Path $Images | Out-Null
  docker build --target importer -t "teledrive-importer:$Version" $Root
  docker build --target bridge -t "teledrive-bridge:$Version" $Root
  docker pull ghcr.io/tgdrive/teldrive:latest
  docker pull ghcr.io/tgdrive/postgres:17-alpine
  docker save -o (Join-Path $Images "teledrive-importer.tar") "teledrive-importer:$Version"
  docker save -o (Join-Path $Images "teledrive-bridge.tar") "teledrive-bridge:$Version"
  docker save -o (Join-Path $Images "teldrive.tar") ghcr.io/tgdrive/teldrive:latest
  docker save -o (Join-Path $Images "postgres.tar") ghcr.io/tgdrive/postgres:17-alpine
}

$Archive = Join-Path $Root "dist\teledrive-$Target-$Arch-$Version.zip"
Remove-Item -Force -ErrorAction SilentlyContinue $Archive
Compress-Archive -Path "$Stage\*" -DestinationPath $Archive
Write-Host "Wrote $Archive"
