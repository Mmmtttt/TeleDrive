param(
  [string]$TeldriveDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($TeldriveDir)) {
  $TeldriveDir = Join-Path (Split-Path -Parent $PSScriptRoot) "third_party/teldrive"
}

$resolved = Resolve-Path $TeldriveDir

function Update-TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New
  )
  $content = Get-Content $Path -Raw
  if (-not $content.Contains($Old)) {
    throw "Expected text not found in $Path"
  }
  $content = $content.Replace($Old, $New)
  Set-Content -Encoding UTF8 -Path $Path -Value $content
}

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20240711163538_search.sql") `
  -Old "CREATE EXTENSION IF NOT EXISTS pgroonga;" `
  -New "-- Native package: PGroonga is optional and not bundled."

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20240711163538_search.sql") `
  -Old "CREATE INDEX name_search_idx ON teldrive.files USING pgroonga (REGEXP_REPLACE(name, '[.,-_]', ' ', 'g')) WITH (tokenizer = 'TokenNgram');" `
  -New "CREATE INDEX name_search_idx ON teldrive.files USING btree (lower(REGEXP_REPLACE(name, '[.,-_]', ' ', 'g')));"

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20240802213957_alter_table.sql") `
  -Old "CREATE INDEX idx_files_name_search ON teldrive.files USING pgroonga (regexp_replace(name, '[.,-_]'::text, ' '::text, 'g'::text)) WITH (tokenizer='TokenNgram');" `
  -New "CREATE INDEX idx_files_name_search ON teldrive.files USING btree (lower(regexp_replace(name, '[.,-_]'::text, ' '::text, 'g'::text)));"

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20241213121739_index.sql") `
  -Old "CREATE INDEX IF NOT EXISTS idx_files_name_search ON teldrive.files USING pgroonga (lower(regexp_replace(name, '[^[:alnum:]\\s]', ' ', 'g'))) WITH (tokenizer='TokenNgram');" `
  -New "CREATE INDEX IF NOT EXISTS idx_files_name_search ON teldrive.files USING btree (lower(regexp_replace(name, '[^[:alnum:]\\s]', ' ', 'g')));"

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20241213121739_index.sql") `
  -Old "CREATE INDEX IF NOT EXISTS idx_files_name_regex_search ON teldrive.files USING pgroonga (name pgroonga_text_regexp_ops_v2);" `
  -New "-- Native package: regex search index requires PGroonga and is skipped."

Update-TextFile `
  -Path (Join-Path $resolved "internal/database/migrations/20260116200000_optimization_bundle.sql") `
  -Old "CREATE INDEX idx_files_name_search ON teldrive.files USING pgroonga (teldrive.clean_name(name)) WITH (tokenizer='TokenNgram');" `
  -New "CREATE INDEX idx_files_name_search ON teldrive.files USING btree (teldrive.clean_name(name));"

Update-TextFile `
  -Path (Join-Path $resolved "pkg/services/file_query_builder.go") `
  -Old '		query = query.Where("teldrive.clean_name(name) &@~ teldrive.clean_name(?)", filesQuery.Query.Value)' `
  -New '		query = query.Where("teldrive.clean_name(name) like ''%'' || teldrive.clean_name(?) || ''%''", filesQuery.Query.Value)'

Update-TextFile `
  -Path (Join-Path $resolved "pkg/services/file_query_builder.go") `
  -Old '		query = query.Where("name &~ ?", filesQuery.Query.Value)' `
  -New '		query = query.Where("name ~* ?", filesQuery.Query.Value)'

Write-Host "Prepared Teldrive native build under $resolved"

