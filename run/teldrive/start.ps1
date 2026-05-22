Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir
try {
  if (-not (Test-Path ".\config.toml")) {
    $templatePath = Join-Path $scriptDir "..\..\deploy\docker\config.template.toml"
    if (-not (Test-Path $templatePath)) {
      throw "Missing config template: $templatePath"
    }
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
      $rng.GetBytes($bytes)
    } finally {
      $rng.Dispose()
    }
    $jwtSecret = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    $content = Get-Content $templatePath -Raw
    $content = $content.Replace("{{POSTGRES_PASSWORD}}", "secret")
    $content = $content.Replace("{{JWT_SECRET}}", $jwtSecret)
    $content = $content.Replace("{{TG_APP_ID}}", "2496")
    $content = $content.Replace("{{TG_APP_HASH}}", "8da85b0d5bfe62527e5b244c209159c3")
    Set-Content -Encoding UTF8 -Path ".\config.toml" -Value $content
    Write-Host "Generated local config.toml"
  }
  docker compose up -d
  docker compose ps
  Write-Host ""
  Write-Host "Teldrive is available at http://127.0.0.1:8787"
  Write-Host "Importer is available at http://127.0.0.1:8891"
  Write-Host "Bridge is available at http://127.0.0.1:8892"
} finally {
  Pop-Location
}
