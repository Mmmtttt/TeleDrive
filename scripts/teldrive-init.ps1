[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$RepoUrl = "https://github.com/tgdrive/teldrive.git",
  [string]$TeldrivePath = "third_party/teldrive",
  [string]$Ref = "",
  [switch]$RegisterSubmodule,
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

$rootIsGit = Test-GitRepo $root

if (-not (Test-Path -LiteralPath $teldriveFullPath)) {
  $parent = Split-Path -Parent $teldriveFullPath
  if (-not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }

  if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Clone $RepoUrl")) {
    Invoke-Checked git @("clone", $RepoUrl, $teldriveFullPath)
  }
} elseif (-not (Test-GitRepo $teldriveFullPath)) {
  throw "$teldriveFullPath exists but is not a git repository."
} else {
  $remote = Invoke-Captured git @("-C", $teldriveFullPath, "config", "--get", "remote.origin.url") -AllowFailure
  if ($remote -and ($remote.Trim() -ne $RepoUrl)) {
    Write-Warning "Existing Teldrive origin is '$remote', expected '$RepoUrl'."
  }
}

Assert-CleanWorktree $teldriveFullPath

if ($Ref) {
  if ($PSCmdlet.ShouldProcess($teldriveFullPath, "Fetch origin and checkout $Ref")) {
    Invoke-Checked git @("-C", $teldriveFullPath, "fetch", "origin", "--tags", "--prune")
    Invoke-Checked git @("-C", $teldriveFullPath, "checkout", "--detach", $Ref)
  }
}

if ($RegisterSubmodule) {
  if (-not $rootIsGit) {
    throw "Parent directory is not a git repository. Run git init first, then rerun with -RegisterSubmodule."
  }

  if ([System.IO.Path]::IsPathRooted($TeldrivePath)) {
    throw "-RegisterSubmodule requires -TeldrivePath to be relative to the project root."
  }

  $submodulePath = $TeldrivePath.Replace("\", "/")
  $gitmodulesPath = Join-Path $root ".gitmodules"
  if (Test-Path -LiteralPath $gitmodulesPath) {
    $submoduleConfig = Invoke-Captured git @("-C", $root, "config", "--file", ".gitmodules", "--get-regexp", "submodule\..*\.path") -AllowFailure
  } else {
    $submoduleConfig = @()
  }
  $alreadyRegistered = $false
  foreach ($line in @($submoduleConfig)) {
    if ($line -match [regex]::Escape($submodulePath)) {
      $alreadyRegistered = $true
    }
  }

  if ($alreadyRegistered) {
    if ($PSCmdlet.ShouldProcess($submodulePath, "Initialize existing submodule")) {
      Invoke-Checked git @("-C", $root, "submodule", "update", "--init", "--recursive", "--", $submodulePath)
    }
  } else {
    if ($PSCmdlet.ShouldProcess($submodulePath, "Register git submodule")) {
      Invoke-Checked git @("-C", $root, "submodule", "add", "--force", $RepoUrl, $submodulePath)
    }
  }
} elseif ($rootIsGit) {
  Write-Host "Parent is a git repository. To register Teldrive as a submodule, rerun with -RegisterSubmodule."
} else {
  Write-Host "Parent is not a git repository. Keeping Teldrive as a plain upstream clone for now."
}

$head = Invoke-Captured git @("-C", $teldriveFullPath, "rev-parse", "HEAD")
$branch = Invoke-Captured git @("-C", $teldriveFullPath, "status", "-sb")
Write-Host "Teldrive path: $teldriveFullPath"
Write-Host "Teldrive HEAD: $head"
Write-Host $branch
