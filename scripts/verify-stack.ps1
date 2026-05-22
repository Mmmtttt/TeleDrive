param(
  [string]$TeldriveUrl = "http://127.0.0.1:8787",
  [string]$ImporterUrl = "http://127.0.0.1:8891",
  [string]$BridgeUrl = "http://127.0.0.1:8892",
  [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

Write-Step "Docker compose services"
$running = @(Invoke-InTeldriveCompose -Arguments @("ps", "--services", "--filter", "status=running"))
foreach ($service in @("postgres", "teldrive", "importer", "bridge")) {
  Assert-True ($running -contains $service) "Service is not running: $service"
  Write-Ok "$service is running"
}

Write-Step "Postgres health"
$pgReady = Invoke-InTeldriveCompose -Arguments @("exec", "-T", "postgres", "pg_isready", "-U", "teldrive", "-d", "postgres")
Write-Ok (($pgReady | Out-String).Trim())

Write-Step "Teldrive HTTP"
try {
  $health = Invoke-HttpRequestCompat -Uri (Join-Url $TeldriveUrl "/health") -TimeoutSec $TimeoutSec
  Write-Ok "Teldrive /health returned HTTP $($health.StatusCode)"
} catch {
  Write-WarnLine "Teldrive /health failed: $($_.Exception.Message)"
  $home = Wait-HttpOk -Uri $TeldriveUrl -TimeoutSec $TimeoutSec
  Write-Ok "Teldrive root returned HTTP $($home.StatusCode)"
}

Write-Step "Importer HTTP"
$importerHealth = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/health") -TimeoutSec $TimeoutSec
Assert-True ($null -ne $importerHealth -and $importerHealth.ok -eq $true) "Importer /health did not return ok=true"
Write-Ok "Importer /health returned ok=true"

Write-Step "Bridge HTTP"
$bridgeHealth = Invoke-JsonRequest -Uri (Join-Url $BridgeUrl "/health") -TimeoutSec $TimeoutSec
Assert-True ($null -ne $bridgeHealth -and $bridgeHealth.ok -eq $true) "Bridge /health did not return ok=true"
Write-Ok "Bridge /health returned ok=true"

Write-Step "Database shape"
$tableCount = [int](Invoke-TeldrivePsql "select count(*) from information_schema.tables where table_schema = 'teldrive' and table_name in ('files', 'sessions', 'channels');")
Assert-True ($tableCount -eq 3) "Expected teldrive.files/sessions/channels tables, got $tableCount"
Write-Ok "Found teldrive.files, teldrive.sessions, teldrive.channels"

$sessionCount = [int](Invoke-TeldrivePsql "select count(*) from teldrive.sessions;")
if ($sessionCount -gt 0) {
  Write-Ok "Teldrive has $sessionCount session row(s)"
} else {
  Write-WarnLine "No Teldrive session rows yet. Log in at $TeldriveUrl before importer/media tests."
}

$selectedChannelCount = [int](Invoke-TeldrivePsql "select count(*) from teldrive.channels where selected = true;")
if ($selectedChannelCount -gt 0) {
  Write-Ok "Teldrive has $selectedChannelCount selected channel row(s)"
} else {
  Write-WarnLine "No selected Teldrive channel found yet. Open Teldrive and select/create a channel first."
}

Write-Ok "Stack verification completed"
