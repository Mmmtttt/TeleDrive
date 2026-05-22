param(
  [string]$ImporterUrl = "http://127.0.0.1:8891",
  [int]$Limit = 20,
  [switch]$DryRunImport,
  [switch]$RunImport,
  [switch]$NoConvertPhotos,
  [switch]$ExpectPolling,
  [int]$WaitForAutoSeconds = 0,
  [int]$TimeoutSec = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

if ($DryRunImport -and $RunImport) {
  throw "Use only one of -DryRunImport or -RunImport."
}

Write-Step "Importer health and status"
$health = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/health") -TimeoutSec 15
Assert-True ($null -ne $health -and $health.ok -eq $true) "Importer /health did not return ok=true"
Write-Ok "Importer /health returned ok=true"

$statusBefore = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/api/status") -TimeoutSec 15
Assert-True ($null -ne $statusBefore -and $statusBefore.ok -eq $true) "Importer /api/status did not return ok=true"
Write-Ok "Importer manual URL: $($statusBefore.manual_url)"
Write-Ok "Importer poll interval: $($statusBefore.poll_interval)"

if ($ExpectPolling) {
  Assert-True ([string]$statusBefore.poll_interval -ne "0s") "Expected automatic polling, but poll_interval is 0s"
} elseif ([string]$statusBefore.poll_interval -eq "0s") {
  Write-WarnLine "Automatic polling is disabled; manual trigger is the current mode."
}

Write-Step "Importer marker table"
$markerTable = [int](Invoke-TeldrivePsql "select count(*) from information_schema.tables where table_schema = 'teldrive_importer' and table_name = 'imported_messages';")
Assert-True ($markerTable -eq 1) "teldrive_importer.imported_messages does not exist"
Write-Ok "Found teldrive_importer.imported_messages"

$statusAfter = $statusBefore
if ($DryRunImport -or $RunImport) {
  Write-Step "Manual import trigger"
  $dryRun = -not $RunImport
  $body = @{
    limit = $Limit
    convert_photos = (-not $NoConvertPhotos)
    dry_run = $dryRun
  }
  $resultEnvelope = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/api/import") -Method "POST" -BodyObject $body -TimeoutSec $TimeoutSec
  Assert-True ($null -ne $resultEnvelope -and $null -ne $resultEnvelope.result) "Importer did not return a result payload"
  $result = $resultEnvelope.result

  if ($dryRun) {
    Write-Ok "Dry-run trigger completed"
  } else {
    Write-Ok "Real import trigger completed"
  }
  Write-Host ("scanned={0} imported={1} converted_photos={2} skipped={3} dry_run={4}" -f $result.scanned, $result.imported, $result.converted_photos, $result.skipped, $result.dry_run)

  $resultErrors = @()
  if ($result.PSObject.Properties.Name -contains "errors" -and $null -ne $result.errors) {
    $resultErrors = @($result.errors)
  }
  if ($resultErrors.Count -gt 0) {
    Write-WarnLine "Importer returned errors:"
    $resultErrors | ForEach-Object { Write-WarnLine $_ }
  }

  $statusAfter = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/api/status") -TimeoutSec 15
  Assert-True ($null -ne $statusAfter.last_result) "Importer status did not record last_result after manual trigger"
  Write-Ok "Importer status recorded last_result"
} else {
  Write-WarnLine "Manual import trigger was not run. Use -DryRunImport or -RunImport to exercise POST /api/import."
}

if ($WaitForAutoSeconds -gt 0) {
  Assert-True ([string]$statusAfter.poll_interval -ne "0s") "Cannot wait for automatic import because poll_interval is 0s"
  Write-Step "Waiting for automatic trigger"
  $beforeFinishedAt = ""
  if ($null -ne $statusAfter.last_result -and $null -ne $statusAfter.last_result.finished_at) {
    $beforeFinishedAt = [string]$statusAfter.last_result.finished_at
  }
  Start-Sleep -Seconds $WaitForAutoSeconds
  $statusAuto = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/api/status") -TimeoutSec 15
  $afterFinishedAt = ""
  if ($null -ne $statusAuto.last_result -and $null -ne $statusAuto.last_result.finished_at) {
    $afterFinishedAt = [string]$statusAuto.last_result.finished_at
  }
  Assert-True ($afterFinishedAt -ne "" -and $afterFinishedAt -ne $beforeFinishedAt) "Automatic polling did not update last_result within $WaitForAutoSeconds second(s)"
  Write-Ok "Automatic polling updated last_result"
}

Write-Ok "Importer verification completed"
