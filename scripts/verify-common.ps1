Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:TeldriveComposeDir = Join-Path $script:RepoRoot "run\teldrive"

function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-WarnLine {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

function Require-Command {
  param([Parameter(Mandatory = $true)][string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-InTeldriveCompose {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  Require-Command "docker"
  Push-Location $script:TeldriveComposeDir
  try {
    $output = & docker compose @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      $text = ($output | Out-String).Trim()
      throw "docker compose $($Arguments -join ' ') failed: $text"
    }
    return $output
  } finally {
    Pop-Location
  }
}

function Invoke-TeldrivePsql {
  param([Parameter(Mandatory = $true)][string]$Sql)

  $args = @(
    "exec", "-T", "postgres",
    "psql", "-U", "teldrive", "-d", "postgres",
    "-t", "-A", "-c", $Sql
  )
  $output = Invoke-InTeldriveCompose -Arguments $args
  return (($output | Out-String).Trim())
}

function Invoke-HttpRequestCompat {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$Method = "GET",
    [hashtable]$Headers,
    [string]$Body,
    [string]$ContentType,
    [int]$TimeoutSec = 15
  )

  $params = @{
    Uri = $Uri
    Method = $Method
    TimeoutSec = $TimeoutSec
    ErrorAction = "Stop"
  }
  if ($PSVersionTable.PSVersion.Major -lt 6) {
    $params.UseBasicParsing = $true
  }
  if ($Headers) {
    $params.Headers = $Headers
  }
  if ($Body) {
    $params.Body = $Body
  }
  if ($ContentType) {
    $params.ContentType = $ContentType
  }

  if ($Headers -and $PSVersionTable.PSVersion.Major -lt 6) {
    foreach ($key in $Headers.Keys) {
      if ([string]::Equals([string]$key, "Range", [System.StringComparison]::OrdinalIgnoreCase)) {
        return Invoke-HttpRequestWithRangeCompat -Uri $Uri -Method $Method -Headers $Headers -Body $Body -ContentType $ContentType -TimeoutSec $TimeoutSec
      }
    }
  }

  return Invoke-WebRequest @params
}

function Invoke-HttpRequestWithRangeCompat {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$Method = "GET",
    [hashtable]$Headers,
    [string]$Body,
    [string]$ContentType,
    [int]$TimeoutSec = 15
  )

  $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
  $request.Method = $Method
  $request.Timeout = $TimeoutSec * 1000
  $request.ReadWriteTimeout = $TimeoutSec * 1000
  if ($ContentType) {
    $request.ContentType = $ContentType
  }

  if ($Headers) {
    foreach ($key in $Headers.Keys) {
      $name = [string]$key
      $value = [string]$Headers[$key]
      if ([string]::Equals($name, "Range", [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($value -match '^bytes=(\d+)-(\d+)$') {
          $request.AddRange([int64]$Matches[1], [int64]$Matches[2])
        } elseif ($value -match '^bytes=(\d+)-$') {
          $request.AddRange([int64]$Matches[1])
        } else {
          throw "Unsupported Range header format for Windows PowerShell: $value"
        }
      } elseif ([string]::Equals($name, "User-Agent", [System.StringComparison]::OrdinalIgnoreCase)) {
        $request.UserAgent = $value
      } elseif ([string]::Equals($name, "Accept", [System.StringComparison]::OrdinalIgnoreCase)) {
        $request.Accept = $value
      } else {
        $request.Headers[$name] = $value
      }
    }
  }

  if ($Body) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $request.ContentLength = $bytes.Length
    $stream = $request.GetRequestStream()
    try {
      $stream.Write($bytes, 0, $bytes.Length)
    } finally {
      $stream.Dispose()
    }
  }

  $response = $null
  try {
    $response = $request.GetResponse()
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) {
      $response = $_.Exception.Response
    } else {
      throw
    }
  }

  try {
    return [pscustomobject]@{
      StatusCode = [int]$response.StatusCode
      Headers = $response.Headers
      Content = ""
    }
  } finally {
    if ($response) {
      $response.Dispose()
    }
  }
}

function Invoke-JsonRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [string]$Method = "GET",
    [object]$BodyObject,
    [int]$TimeoutSec = 60
  )

  $body = $null
  if ($null -ne $BodyObject) {
    $body = $BodyObject | ConvertTo-Json -Depth 8 -Compress
  }

  $response = Invoke-HttpRequestCompat `
    -Uri $Uri `
    -Method $Method `
    -Body $body `
    -ContentType "application/json" `
    -TimeoutSec $TimeoutSec

  if ([string]::IsNullOrWhiteSpace($response.Content)) {
    return $null
  }
  return $response.Content | ConvertFrom-Json
}

function Wait-HttpOk {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 30
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $lastError = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-HttpRequestCompat -Uri $Uri -TimeoutSec 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        return $response
      }
    } catch {
      $lastError = $_.Exception.Message
    }
    Start-Sleep -Seconds 1
  }

  if ($lastError) {
    throw "Timed out waiting for $Uri. Last error: $lastError"
  }
  throw "Timed out waiting for $Uri"
}

function ConvertFrom-PsqlJson {
  param([Parameter(Mandatory = $true)][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return @()
  }
  return $Text | ConvertFrom-Json
}

function Get-HeaderValue {
  param(
    [Parameter(Mandatory = $true)]$Headers,
    [Parameter(Mandatory = $true)][string]$Name
  )

  foreach ($key in $Headers.Keys) {
    if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
      $value = $Headers[$key]
      if ($value -is [array]) {
        return ($value -join ", ")
      }
      return [string]$value
    }
  }
  return $null
}

function Join-Url {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$Path
  )

  if ($Path.StartsWith("http://") -or $Path.StartsWith("https://")) {
    return $Path
  }
  return $BaseUrl.TrimEnd("/") + "/" + $Path.TrimStart("/")
}
