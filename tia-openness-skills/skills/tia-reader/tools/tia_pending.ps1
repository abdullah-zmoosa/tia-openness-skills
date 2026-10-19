# tia_pending.ps1 - queue project(s) for export when this logon lacks the Openness group,
# and print the one fixed runas command the user must run.
# Converts mapped drives (X: etc.) to UNC, because runas sessions have no mapped drives.
#
# Usage: powershell -ExecutionPolicy Bypass -File tia_pending.ps1 -Project "<path1>","<path2>"

param([Parameter(Mandatory=$true)][string[]]$Project)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tia_common.ps1"

$root = Get-TiaExportRoot
New-Item -ItemType Directory -Force $root | Out-Null
$pending = Join-Path $root 'PENDING.txt'
$lines = @()
foreach ($p in $Project) {
    foreach ($q in ($p -split ',')) {
        $q = $q.Trim(); if (-not $q) { continue }
        if (-not (Test-Path $q)) { throw "Not found: $q" }
        $lines += ConvertTo-TiaUncPath (Resolve-Path $q).Path
    }
}
Set-Content -Path $pending -Value $lines -Encoding ascii
"Queued in $pending :"
$lines | ForEach-Object { "  $_" }
""
"Ask the user to run this (Win+R or a terminal; it asks for their Windows password):"
""
"runas /user:$env:USERDOMAIN\$env:USERNAME `"powershell -ExecutionPolicy Bypass -File $PSScriptRoot\run_pending.ps1`""
