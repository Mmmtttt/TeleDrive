param(
  [string]$DemoUrl = "http://127.0.0.1:8890",
  [int]$MinItems = 0,
  [switch]$RequireMedia,
  [switch]$RequireImage,
  [switch]$RequireVideo,
  [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

Write-Step "Demo HTTP"
$home = Wait-HttpOk -Uri $DemoUrl -TimeoutSec $TimeoutSec
Write-Ok "Demo root returned HTTP $($home.StatusCode)"

Write-Step "Demo catalog"
$catalog = Invoke-JsonRequest -Uri (Join-Url $DemoUrl "/api/catalog") -TimeoutSec $TimeoutSec
Assert-True ($null -ne $catalog) "Demo /api/catalog returned an empty response"
Assert-True ($catalog.PSObject.Properties.Name -contains "items") "Demo /api/catalog did not include items"

$items = @($catalog.items)
$count = $items.Count
Assert-True ($count -ge $MinItems) "Catalog item count $count is below MinItems=$MinItems"
if ($RequireMedia) {
  Assert-True ($count -gt 0) "Catalog has no media items"
}
if ($RequireImage) {
  Assert-True (($items | Where-Object { $_.kind -eq "image" } | Select-Object -First 1) -ne $null) "Catalog has no image items"
}
if ($RequireVideo) {
  Assert-True (($items | Where-Object { $_.kind -eq "video" } | Select-Object -First 1) -ne $null) "Catalog has no video items"
}

Write-Ok "Catalog returned $count item(s)"
$items | Select-Object -First 8 id, kind, name, mime_type, size, media_url | Format-Table -AutoSize

Write-Ok "Demo catalog verification completed"
