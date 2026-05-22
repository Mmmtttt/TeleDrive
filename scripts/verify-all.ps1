param(
  [switch]$StrictMedia,
  [switch]$DryRunImport,
  [switch]$RunImport,
  [int]$ImportLimit = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($DryRunImport -and $RunImport) {
  throw "Use only one of -DryRunImport or -RunImport."
}

Write-Host "Running TeleDrive verification suite"

& "$PSScriptRoot\verify-stack.ps1"
& "$PSScriptRoot\verify-bridge.ps1"

$importerArgs = @("-Limit", $ImportLimit)
if ($DryRunImport) {
  $importerArgs += "-DryRunImport"
}
if ($RunImport) {
  $importerArgs += "-RunImport"
}
& "$PSScriptRoot\verify-importer.ps1" @importerArgs

if ($StrictMedia) {
  & "$PSScriptRoot\verify-bridge.ps1" -RequireMedia -RequireVideo
  & "$PSScriptRoot\verify-demo-catalog.ps1" -RequireMedia
  & "$PSScriptRoot\verify-video-range.ps1"
  & "$PSScriptRoot\verify-photo-document.ps1" -RequireConverted
} else {
  & "$PSScriptRoot\verify-demo-catalog.ps1"
  try {
    & "$PSScriptRoot\verify-video-range.ps1"
  } catch {
    Write-Host "[WARN] Video Range check skipped/failed in non-strict mode: $($_.Exception.Message)" -ForegroundColor Yellow
  }
  try {
    & "$PSScriptRoot\verify-photo-document.ps1"
  } catch {
    Write-Host "[WARN] Photo document check skipped/failed in non-strict mode: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "[OK] Verification suite completed" -ForegroundColor Green
