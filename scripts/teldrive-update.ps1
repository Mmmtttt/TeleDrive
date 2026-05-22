[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$TeldrivePath = "third_party/teldrive",
  [string]$Remote = "origin",
  [string]$Ref = "origin/main",
  [switch]$NoFetch,
  [switch]$AllowDirty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Invoke-Captured {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & $FilePath @Arguments
  $code = $LASTEXITCODE
  if (($code -ne 0) -and (-not $AllowFailure)) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $code"
  }
  return $output
}

function Test-GitRepo {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  & git -C $Path rev-parse --is-inside-work-tree *> $null
  return ($LASTEXITCODE -eq 0)
}

function Assert-CleanWorktree {
  param([string]$Path)

  if ($AllowDirty) {
    return
  }

  $status = Invoke-Captured git @("-C", $Path, "status", "--porcelain")
  if ($status) {
    throw "Teldrive worktree is dirty. Commit/stash it or rerun with -AllowDirty."
  }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git is required but was not found in PATH."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$teldriveFullPath = if ([System.IO.Path]::IsPathRooted($TeldrivePath)) {
  $TeldrivePath
} else {
  Join-Path $root $TeldrivePath
}

if (-not (Test-GitRepo $teldriveFullPath)) {
  throw "$teldriveFullPath is not a git repository. Run scripts/teldrive-init.ps1 first."
}

Assert-CleanWorktree $teldriveFullPath

$before = Invoke-Captured git @("-C", $teldriveFullPath, "rev-parse", "HEAD")

if (-not $NoFetch) {
  if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Fetch $Remote with tags and prune")) {
    Invoke-Checked git @("-C", $teldriveFullPath, "fetch", $Remote, "--tags", "--prune")
  }
}

$target = Invoke-Captured git @("-C", $teldriveFullPath, "rev-parse", "$Ref^{commit}")

if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Checkout detached $target")) {
  Invoke-Checked git @("-C", $teldriveFullPath, "checkout", "--detach", $target)
}

$after = Invoke-Captured git @("-C", $teldriveFullPath, "rev-parse", "HEAD")
$status = Invoke-Captured git @("-C", $teldriveFullPath, "status", "-sb")

Write-Host "Teldrive before: $before"
Write-Host "Teldrive after:  $after"
Write-Host $status

if (Test-GitRepo $root) {
  Write-Host "Parent git repository detected. Review and commit the submodule pointer if this update is intended:"
  Write-Host "  git add $TeldrivePath"
}
