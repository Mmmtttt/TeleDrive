Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$connections = Get-NetTCPConnection -LocalPort 8890 -State Listen -ErrorAction SilentlyContinue
foreach ($connection in $connections) {
  if ($connection.OwningProcess) {
    Stop-Process -Id $connection.OwningProcess -Force
  }
}
