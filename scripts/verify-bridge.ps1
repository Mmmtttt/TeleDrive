param(
  [string]$BridgeUrl = "http://127.0.0.1:8892",
  [switch]$RequireMedia,
  [switch]$RequireVideo,
  [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

Write-Step "Bridge health"
$health = Invoke-JsonRequest -Uri (Join-Url $BridgeUrl "/health") -TimeoutSec $TimeoutSec
Assert-True ($null -ne $health -and $health.ok -eq $true) "Bridge /health did not return ok=true"
Write-Ok "Bridge /health returned ok=true"

Write-Step "Bridge catalog"
$catalog = Invoke-JsonRequest -Uri (Join-Url $BridgeUrl "/v1/catalog/items") -TimeoutSec $TimeoutSec
Assert-True ($null -ne $catalog) "Bridge catalog returned an empty response"
Assert-True ($catalog.PSObject.Properties.Name -contains "items") "Bridge catalog did not include items"
$items = @($catalog.items)
Write-Ok "Bridge catalog returned $($items.Count) item(s)"

if ($RequireMedia) {
  Assert-True ($items.Count -gt 0) "Bridge catalog has no media items"
}

$video = $items | Where-Object { $_.kind -eq "video" } | Select-Object -First 1
if ($RequireVideo) {
  Assert-True ($null -ne $video) "Bridge catalog has no video item"
}

if ($null -ne $video) {
  Write-Step "Bridge video Range"
  $mediaUrl = Join-Url $BridgeUrl $video.media_url
  $response = Invoke-HttpRequestCompat -Uri $mediaUrl -Headers @{ Range = "bytes=0-1023" } -TimeoutSec $TimeoutSec
  Assert-True ([int]$response.StatusCode -eq 206) "Expected HTTP 206 from Bridge media proxy, got $($response.StatusCode)"
  $contentRange = Get-HeaderValue -Headers $response.Headers -Name "Content-Range"
  Assert-True (-not [string]::IsNullOrWhiteSpace($contentRange)) "Bridge media response did not include Content-Range"
  Write-Ok "Bridge media Range returned 206 with $contentRange"
} else {
  Write-WarnLine "No video item found; Bridge Range check skipped."
}

Write-Ok "Bridge verification completed"
