param(
  [switch]$NoLoadImages
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function New-Secret {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Get-PackageVersion {
  $versionPath = Join-Path $Root "VERSION"
  if (Test-Path $versionPath) {
    return (Get-Content $versionPath -Raw).Trim()
  }
  return "local"
}

function Write-DefaultEnv {
  $version = Get-PackageVersion
  $postgresPassword = New-Secret
  $jwtSecret = New-Secret
  $bridgeToken = New-Secret
  @(
    "TELEDRIVE_VERSION=$version",
    "POSTGRES_IMAGE=ghcr.io/tgdrive/postgres:17-alpine",
    "TELDRIVE_IMAGE=ghcr.io/tgdrive/teldrive:latest",
    "POSTGRES_USER=teldrive",
    "POSTGRES_PASSWORD=$postgresPassword",
    "POSTGRES_DB=postgres",
    "TELDRIVE_PORT=8787",
    "IMPORTER_PORT=8891",
    "BRIDGE_PORT=8892",
    "BRIDGE_TOKEN=$bridgeToken",
    "DEFAULT_LIMIT=100",
    "POLL_INTERVAL_SECONDS=0",
    "IMPORT_FOLDER=Telegram Imports",
    "CATALOG_LIMIT=100",
    "TG_APP_ID=2496",
    "TG_APP_HASH=8da85b0d5bfe62527e5b244c209159c3",
    "JWT_SECRET=$jwtSecret"
  ) | Set-Content -Encoding UTF8 -Path (Join-Path $Root ".env")
}

function Read-DotEnv {
  $map = @{}
  $envPath = Join-Path $Root ".env"
  foreach ($line in Get-Content $envPath) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
      continue
    }
    $idx = $trimmed.IndexOf("=")
    if ($idx -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $idx)
    $value = $trimmed.Substring($idx + 1)
    $map[$key] = $value
  }
  return $map
}

function Get-EnvValue {
  param(
    [hashtable]$Map,
    [string]$Key,
    [string]$Fallback
  )
  if ($Map.ContainsKey($Key) -and $Map[$Key] -ne "") {
    return $Map[$Key]
  }
  return $Fallback
}

function Write-Config {
  param([hashtable]$EnvMap)
  $templatePath = Join-Path $Root "config.template.toml"
  $configPath = Join-Path $Root "config.toml"
  if (-not (Test-Path $templatePath)) {
    throw "Missing config.template.toml"
  }
  $content = Get-Content $templatePath -Raw
  $content = $content.Replace("{{POSTGRES_PASSWORD}}", (Get-EnvValue $EnvMap "POSTGRES_PASSWORD" "change-me"))
  $content = $content.Replace("{{JWT_SECRET}}", (Get-EnvValue $EnvMap "JWT_SECRET" (New-Secret)))
  $content = $content.Replace("{{TG_APP_ID}}", (Get-EnvValue $EnvMap "TG_APP_ID" "2496"))
  $content = $content.Replace("{{TG_APP_HASH}}", (Get-EnvValue $EnvMap "TG_APP_HASH" "8da85b0d5bfe62527e5b244c209159c3"))
  Set-Content -Encoding UTF8 -Path $configPath -Value $content
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is required to run the full offline TeleDrive stack."
}

if (-not (Test-Path (Join-Path $Root ".env"))) {
  Write-DefaultEnv
}

$envMap = Read-DotEnv
if (-not (Test-Path (Join-Path $Root "config.toml"))) {
  Write-Config $envMap
}

if (-not $NoLoadImages) {
  $imageDir = Join-Path $Root "images"
  if (Test-Path $imageDir) {
    Get-ChildItem -Path $imageDir -Filter *.tar | Sort-Object Name | ForEach-Object {
      Write-Host "Loading image $($_.Name)"
      docker load --input $_.FullName
    }
  }
}

docker compose --env-file .env -f docker-compose.yml up -d

Write-Host ""
Write-Host "TeleDrive is starting."
Write-Host "Teldrive: http://127.0.0.1:$((Get-EnvValue $envMap "TELDRIVE_PORT" "8787"))"
Write-Host "Importer: http://127.0.0.1:$((Get-EnvValue $envMap "IMPORTER_PORT" "8891"))"
Write-Host "Bridge:   http://127.0.0.1:$((Get-EnvValue $envMap "BRIDGE_PORT" "8892"))"
