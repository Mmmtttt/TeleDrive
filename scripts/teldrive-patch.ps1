[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateSet("Status", "ExportDiff", "ExportFormatPatch", "ApplyDiff", "ApplyMailbox")]
  [string]$Mode = "Status",
  [string]$TeldrivePath = "third_party/teldrive",
  [string]$BaseRef = "origin/main",
  [string]$OutputFile = "",
  [string]$PatchFile = "",
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

function Resolve-ProjectPath {
  param([string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return (Join-Path $root $Path)
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git is required but was not found in PATH."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$teldriveFullPath = Resolve-ProjectPath $TeldrivePath

if (-not (Test-GitRepo $teldriveFullPath)) {
  throw "$teldriveFullPath is not a git repository. Run scripts/teldrive-init.ps1 first."
}

switch ($Mode) {
  "Status" {
    Invoke-Checked git @("-C", $teldriveFullPath, "status", "-sb")
    Invoke-Checked git @("-C", $teldriveFullPath, "log", "--oneline", "--decorate", "-n", "12")
  }

  "ExportDiff" {
    if (-not $OutputFile) {
      throw "-OutputFile is required for ExportDiff."
    }

    Assert-CleanWorktree $teldriveFullPath
    $outputPath = Resolve-ProjectPath $OutputFile
    $outputParent = Split-Path -Parent $outputPath
    if ($outputParent -and (-not (Test-Path -LiteralPath $outputParent))) {
      New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }

    $diff = Invoke-Captured git @("-C", $teldriveFullPath, "diff", "--binary", "$BaseRef...HEAD")
    if ($PSCmdlet.ShouldProcess($outputPath, "Write exported git diff")) {
      Set-Content -LiteralPath $outputPath -Value $diff -Encoding UTF8
    }
    Write-Host "Wrote diff patch: $outputPath"
  }

  "ExportFormatPatch" {
    if (-not $OutputFile) {
      throw "-OutputFile is required for ExportFormatPatch."
    }

    Assert-CleanWorktree $teldriveFullPath
    $outputPath = Resolve-ProjectPath $OutputFile
    $outputParent = Split-Path -Parent $outputPath
    if ($outputParent -and (-not (Test-Path -LiteralPath $outputParent))) {
      New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    }

    $patch = Invoke-Captured git @("-C", $teldriveFullPath, "format-patch", "--stdout", "$BaseRef..HEAD")
    if ($PSCmdlet.ShouldProcess($outputPath, "Write exported format-patch mailbox")) {
      Set-Content -LiteralPath $outputPath -Value $patch -Encoding UTF8
    }
    Write-Host "Wrote format-patch mailbox: $outputPath"
  }

  "ApplyDiff" {
    if (-not $PatchFile) {
      throw "-PatchFile is required for ApplyDiff."
    }

    Assert-CleanWorktree $teldriveFullPath
    $patchPath = Resolve-ProjectPath $PatchFile
    if (-not (Test-Path -LiteralPath $patchPath)) {
      throw "Patch file not found: $patchPath"
    }

    Invoke-Checked git @("-C", $teldriveFullPath, "apply", "--check", $patchPath)
    if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Apply diff patch $patchPath")) {
      Invoke-Checked git @("-C", $teldriveFullPath, "apply", $patchPath)
    }
  }

  "ApplyMailbox" {
    if (-not $PatchFile) {
      throw "-PatchFile is required for ApplyMailbox."
    }

    Assert-CleanWorktree $teldriveFullPath
    $patchPath = Resolve-ProjectPath $PatchFile
    if (-not (Test-Path -LiteralPath $patchPath)) {
      throw "Patch file not found: $patchPath"
    }

    if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Apply format-patch mailbox $patchPath")) {
      Invoke-Checked git @("-C", $teldriveFullPath, "am", "--3way", $patchPath)
    }
  }
}
