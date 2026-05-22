param(
  [string]$ImporterUrl = "http://127.0.0.1:8891",
  [int]$Limit = 50,
  [switch]$RunImport,
  [switch]$DryRun,
  [int]$Recent = 10,
  [int]$OriginalMessageId = 0,
  [switch]$RequireConverted,
  [int]$TimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

if ($RunImport) {
  Write-Step "Trigger photo conversion import"
  $body = @{
    limit = $Limit
    convert_photos = $true
    dry_run = [bool]$DryRun
  }
  $resultEnvelope = Invoke-JsonRequest -Uri (Join-Url $ImporterUrl "/api/import") -Method "POST" -BodyObject $body -TimeoutSec $TimeoutSec
  Assert-True ($null -ne $resultEnvelope -and $null -ne $resultEnvelope.result) "Importer did not return a result payload"
  $result = $resultEnvelope.result
  Write-Host ("scanned={0} imported={1} converted_photos={2} skipped={3} dry_run={4}" -f $result.scanned, $result.imported, $result.converted_photos, $result.skipped, $result.dry_run)
  if ($DryRun) {
    Write-WarnLine "Dry-run does not create converted document rows; database verification below checks existing imports only."
  }
}

Write-Step "Converted photo records"
$tableCount = [int](Invoke-TeldrivePsql "select count(*) from information_schema.tables where table_schema = 'teldrive_importer' and table_name = 'imported_messages';")
Assert-True ($tableCount -eq 1) "teldrive_importer.imported_messages does not exist. Start importer once before this check."

$where = "im.converted = true"
if ($OriginalMessageId -gt 0) {
  $where = "$where and im.original_msg_id = $OriginalMessageId"
}

$sql = @"
select coalesce(json_agg(row_to_json(x)), '[]'::json)
from (
  select
    im.original_msg_id,
    im.imported_msg_id,
    im.file_id::text,
    im.name,
    im.converted,
    f.name as file_name,
    f.mime_type,
    f.category,
    f.status,
    f.parts
  from teldrive_importer.imported_messages im
  left join teldrive.files f on f.id = im.file_id
  where $where
  order by im.created_at desc
  limit $Recent
) x;
"@

$rows = @(ConvertFrom-PsqlJson (Invoke-TeldrivePsql $sql))
if ($RequireConverted -or $OriginalMessageId -gt 0) {
  Assert-True ($rows.Count -gt 0) "No converted photo document records found"
} elseif ($rows.Count -eq 0) {
  Write-WarnLine "No converted photo document records found yet. Forward a normal Telegram photo, then run this script with -RunImport."
}

foreach ($row in $rows) {
  Assert-True ($row.converted -eq $true) "Record original_msg_id=$($row.original_msg_id) is not marked converted"
  Assert-True ($row.status -eq "active") "Converted file original_msg_id=$($row.original_msg_id) is not active"
  Assert-True ([string]$row.mime_type -like "image/*") "Converted file original_msg_id=$($row.original_msg_id) has unexpected mime_type=$($row.mime_type)"
  Assert-True ([string]$row.category -eq "image") "Converted file original_msg_id=$($row.original_msg_id) has unexpected category=$($row.category)"

  $partIds = @()
  if ($null -ne $row.parts) {
    $partIds = @($row.parts | ForEach-Object { [int]$_.id })
  }
  Assert-True ($partIds -contains [int]$row.imported_msg_id) "Converted file original_msg_id=$($row.original_msg_id) parts do not include imported_msg_id=$($row.imported_msg_id)"
}

if ($rows.Count -gt 0) {
  Write-Ok "Verified $($rows.Count) converted photo document record(s)"
  $rows | Select-Object original_msg_id, imported_msg_id, file_id, file_name, mime_type, category, status | Format-Table -AutoSize
}

Write-Ok "Photo-to-document verification completed"
