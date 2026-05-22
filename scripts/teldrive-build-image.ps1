[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$TeldrivePath = "third_party/teldrive",
  [string]$ImageTag = "local/teldrive:dev",
  [string]$Platform = "linux/amd64",
  [string]$Version = "",
  [string]$FrontendAsset = "https://github.com/tgdrive/teldrive-ui/releases/download/latest/teldrive-ui.zip",
  [switch]$Push,
  [switch]$NoLoad,
  [switch]$PlainProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "docker is required but was not found in PATH."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$teldriveFullPath = if ([System.IO.Path]::IsPathRooted($TeldrivePath)) {
  $TeldrivePath
} else {
  Join-Path $root $TeldrivePath
}

if (-not (Test-Path -LiteralPath (Join-Path $teldriveFullPath "go.mod"))) {
  throw "$teldriveFullPath does not look like a Teldrive source tree."
}

if (-not $Version) {
  $versionFile = Join-Path $teldriveFullPath "VERSION"
  if (Test-Path -LiteralPath $versionFile) {
    $Version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
  } else {
    $Version = "custom"
  }
}

if (Test-GitRepo $teldriveFullPath) {
  $commit = (Invoke-Captured git @("-C", $teldriveFullPath, "rev-parse", "--short", "HEAD")).Trim()
} else {
  $commit = "nogit"
}

if (($Platform -like "*,*") -and (-not $Push) -and (-not $NoLoad)) {
  throw "Docker buildx cannot --load multiple platforms. Use -Push or -NoLoad for multi-platform builds."
}

$dockerfile = @'
# syntax=docker/dockerfile:1.7
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=custom
ARG COMMIT=custom
ARG FRONTEND_ASSET=https://github.com/tgdrive/teldrive-ui/releases/download/latest/teldrive-ui.zip

RUN apk add --no-cache ca-certificates git
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
RUN go run scripts/extract.go -url "${FRONTEND_ASSET}" -output ui/dist
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build go generate ./...
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    MODULE_PATH="$(go list -m)" && \
    CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go build -trimpath \
      -ldflags "-s -w -X ${MODULE_PATH}/internal/version.Version=${VERSION} -X ${MODULE_PATH}/internal/version.CommitSHA=${COMMIT}" \
      -o /out/teldrive .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /out/teldrive /teldrive
EXPOSE 8080
ENTRYPOINT ["/teldrive", "run"]
'@

$dockerArgs = @(
  "buildx", "build",
  "--file", "-",
  "--tag", $ImageTag,
  "--platform", $Platform,
  "--build-arg", "VERSION=$Version",
  "--build-arg", "COMMIT=$commit",
  "--build-arg", "FRONTEND_ASSET=$FrontendAsset"
)

if ($PlainProgress) {
  $dockerArgs += @("--progress", "plain")
}

if ($Push) {
  $dockerArgs += "--push"
} elseif (-not $NoLoad) {
  $dockerArgs += "--load"
}

$dockerArgs += $teldriveFullPath

Write-Host "Building Teldrive image $ImageTag from $teldriveFullPath"
Write-Host "Version: $Version"
Write-Host "Commit:  $commit"
Write-Host "Platform: $Platform"

if ($PSCmdlet.ShouldProcess($ImageTag, "docker $($dockerArgs -join ' ')")) {
  $dockerfile | & docker @dockerArgs
  if ($LASTEXITCODE -ne 0) {
    throw "docker $($dockerArgs -join ' ') failed with exit code $LASTEXITCODE"
  }
}
