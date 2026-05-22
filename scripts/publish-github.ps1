param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryUrl,
  [string]$Remote = "origin",
  [string]$Branch = "main",
  [switch]$PushTags
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
  $inside = git rev-parse --is-inside-work-tree
  if ($inside -ne "true") {
    throw "Not inside a git repository: $repoRoot"
  }

  $dirty = git status --porcelain
  if ($dirty) {
    throw "Working tree is not clean. Commit or stash changes before publishing."
  }

  $existing = git remote get-url $Remote 2>$null
  if ($LASTEXITCODE -eq 0 -and $existing) {
    git remote set-url $Remote $RepositoryUrl
  } else {
    git remote add $Remote $RepositoryUrl
  }

  git push -u $Remote $Branch
  if ($PushTags) {
    git push $Remote --tags
  }
} finally {
  Pop-Location
}
