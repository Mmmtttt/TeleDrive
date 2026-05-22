param(
  [string]$DemoUrl = "http://127.0.0.1:8890",
  [string]$FileId = "",
  [string]$FileName = "",
  [string]$Range = "bytes=0-1023",
  [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\verify-common.ps1"

Write-Step "Resolve video media URL"
$mediaPath = ""
if ($FileId -and $FileName) {
  $mediaPath = "/media/$([uri]::EscapeDataString($FileId))/$([uri]::EscapeDataString($FileName))"
} else {
  $catalog = Invoke-JsonRequest -Uri (Join-Url $DemoUrl "/api/catalog") -TimeoutSec $TimeoutSec
  $video = @($catalog.items) | Where-Object { $_.kind -eq "video" -or ([string]$_.mime_type).StartsWith("video/") } | Select-Object -First 1
  Assert-True ($null -ne $video) "No video item found in demo catalog. Import or upload a video first, then rerun this script."
  $mediaPath = [string]$video.media_url
  Write-Ok "Using catalog video: $($video.name)"
}

$mediaUrl = Join-Url $DemoUrl $mediaPath
Write-Ok "Testing $mediaUrl"

Write-Step "HEAD request with Range"
$headers = @{ Range = $Range }
$response = Invoke-HttpRequestCompat -Uri $mediaUrl -Method "HEAD" -Headers $headers -TimeoutSec $TimeoutSec

Assert-True ($response.StatusCode -eq 206) "Expected HTTP 206 Partial Content, got HTTP $($response.StatusCode)"
$contentRange = Get-HeaderValue -Headers $response.Headers -Name "Content-Range"
Assert-True (-not [string]::IsNullOrWhiteSpace($contentRange)) "Missing Content-Range header"
$acceptRanges = Get-HeaderValue -Headers $response.Headers -Name "Accept-Ranges"

Write-Ok "Range response returned HTTP 206"
Write-Ok "Content-Range: $contentRange"
if ($acceptRanges) {
  Write-Ok "Accept-Ranges: $acceptRanges"
} else {
  Write-WarnLine "Accept-Ranges header was not present"
}

Write-Ok "Video Range verification completed"
