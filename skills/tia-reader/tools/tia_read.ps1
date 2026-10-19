# tia_read.ps1 - export a TIA Portal project to readable text (copy-only, read-only)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tia_read.ps1 -Project <.apNN | .zapNN | project folder> [-Out <dir>] [-Pause]
#
# What it does:
#   1. .apNN  -> copies the whole project folder to <Out>\_src first (original never opened)
#      .zapNN -> retrieves the archive into <Out>\export\_retrieved (archive untouched)
#   2. Opens the copy headless via TIA V20 Openness (older versions are upgraded - the copy only)
#   3. Compiles the copy (upgraded projects are inconsistent and won't export otherwise)
#   4. Exports blocks, UDTs, TOs, PLC tags, watch tables, HMI (classic), hardware
#   5. Renders SCL (.scl), LAD/FBD (.lad.txt), STL (.stl), tags/HMI/screens (.txt)
#
# Requires: TIA Portal V20 installed, user in local group 'Siemens TIA Openness'.
# If the group was added in this Windows session, run via:  runas /user:<DOMAIN>\<user> "powershell ..."

param(
    [Parameter(Mandatory=$true)][string]$Project,
    [string]$Out,
    [switch]$Pause
)
$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
. "$tools\tia_common.ps1"
$root  = Get-TiaExportRoot
New-Item -ItemType Directory -Force $root | Out-Null

# Resolve project file
if (Test-Path $Project -PathType Container) {
    $f = Get-ChildItem $Project -File | Where-Object { $_.Extension -match '^\.(ap|zap)\d+$' } | Select-Object -First 1
    if (-not $f) { throw "No .apNN / .zapNN file in folder: $Project" }
    $Project = $f.FullName
}
if (-not (Test-Path $Project)) { throw "Project not found: $Project" }
$pf   = Get-Item $Project
$name = $pf.BaseName
if (-not $Out) { $Out = Join-Path $root ($name + '_' + (Get-Date -Format 'yyyyMMdd_HHmm')) }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path $Out).Path

Start-Transcript -Path (Join-Path $Out 'export.log') -Force | Out-Null
$failed = $false
try {
    "Project : $($pf.FullName)"
    "Out     : $Out"
    if (Test-TiaOpennessGroup) { 'Openness group: OK' }
    else { 'Openness group: MISSING in this logon - use tia_pending.ps1 + runas (see SKILL.md) or sign out/in' }

    # Openness DLL (V20 opens V17-V20 projects via upgrade-on-copy)
    $dll = Get-TiaDll
    "Openness: $dll"

    # Work on a copy, never the original
    if ($pf.Extension -match '^\.ap\d+$') {
        $src = Join-Path $Out '_src'
        if (Test-Path $src) { Remove-Item $src -Recurse -Force }
        New-Item -ItemType Directory $src | Out-Null
        "Copying project folder to $src ..."
        Copy-Item $pf.Directory.FullName (Join-Path $src $pf.Directory.Name) -Recurse -Force
        $work = Join-Path (Join-Path $src $pf.Directory.Name) $pf.Name
        # TIA lock files from an open UI session would block the headless open
        Get-ChildItem (Split-Path $work) -Recurse -Include *.lck -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } else {
        $work = $pf.FullName   # .zap: resolver retrieves it into export\_retrieved
    }

    $exp = Join-Path $Out 'export'
    & "$tools\export_tia.ps1" -Project $work -Out $exp -Dll $dll

    $py = Get-TiaPython
    if (Test-Path "$exp\blocks") {
        & "$tools\extract_scl.ps1" -BlocksDir "$exp\blocks"
        & $py -I "$tools\render_lad.py" "$exp\blocks"
        & $py -I "$tools\stl_dump.py"   "$exp\blocks"
    }
    & $py -I "$tools\simaticml_flat.py" $exp

    Set-Content -Path (Join-Path $root 'LATEST.txt') -Value $Out -Encoding ascii
    "=== DONE === -> $Out"
}
catch {
    "=== FAILED === $($_.Exception.Message)"
    $failed = $true
}
finally {
    Stop-Transcript | Out-Null
    if ($Pause) { Read-Host 'Finished - press Enter to close' }
}
if ($failed) { exit 1 }
