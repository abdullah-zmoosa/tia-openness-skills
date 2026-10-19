# export_tia.ps1 - TIA Portal V20 Openness export script
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File export_tia.ps1 -Project <path.ap20> -Out <dir> [-Probe]
#
# -Probe  : Write only manifest.json (block inventory, no source files). Fast.
# Full    : Write blocks/<name>.xml + udt/<name>.xml + manifest.json.
#
# Requirements:
#   1. User must be in local group "Siemens TIA Openness" (whitelist).
#   2. Target .ap20 project must NOT be open exclusively in TIA Portal UI.
#   3. TIA V20 Openness DLL (-Dll, or auto-detected by tia_common.ps1).
#   4. PowerShell 5.1+ / .NET 4.7+

param(
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$Out,
    [switch]$Probe,
    # Openness is version-locked: the V20 DLL opens V20 projects and upgrades older ones (in the copy).
    [string]$Dll = ""
)
if (-not $Dll) { . "$PSScriptRoot\tia_common.ps1"; $Dll = Get-TiaDll }

$ErrorActionPreference = 'Stop'

# Pre-flight checks

$dll = $Dll
if (-not (Test-Path $dll)) {
    throw "Openness DLL not found: $dll"
}

if (-not (Test-Path $Project)) {
    throw "Project file not found: $Project"
}

# Normalize -Out to an ABSOLUTE path.
# TIA Openness block.Export() rejects relative paths ("argument 'path' cannot be a
# relative path"), and the headless TiaPortal process CWD differs from PowerShell's,
# so a relative -Out silently writes nowhere useful.
if (-not [System.IO.Path]::IsPathRooted($Out)) {
    $Out = Join-Path (Get-Location).Path $Out
}
$Out = [System.IO.Path]::GetFullPath($Out)

# Full export: clear prior block/udt files first. Openness Export() refuses to
# overwrite ("file ... already exists") and SKIPs the block, leaving STALE exports
# from a previous run. Clearing guarantees the dump reflects the current project.
# (Probe writes only manifest.json via WriteAllText, which overwrites cleanly.)
if (-not $Probe) {
    Remove-Item -LiteralPath (Join-Path $Out 'blocks') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Out 'udt')    -Recurse -Force -ErrorAction SilentlyContinue
}

# Advisory group check (non-fatal - some setups use domain groups)
$groupCheckOk = $false
try {
    $groups = (whoami /groups) -join "`n"
    if ($groups -match 'Siemens TIA Openness') {
        $groupCheckOk = $true
    }
} catch {
    # ignore - whoami may not be available in all contexts
}
if (-not $groupCheckOk) {
    Write-Warning "User may not be in 'Siemens TIA Openness' local group - Portal may refuse to start."
    Write-Warning "Add user via: lusrmgr.msc -> Groups -> 'Siemens TIA Openness' -> Add."
}

# Load C# helper (compile once per session)

$csPath = "$PSScriptRoot\OpennessResolver.cs"
if (-not (Test-Path $csPath)) {
    throw "OpennessResolver.cs not found at $csPath"
}

if (-not ([System.Management.Automation.PSTypeName]'Exporter').Type) {
    Write-Host "Compiling OpennessResolver.cs..."
    $cs = Get-Content $csPath -Raw
    Add-Type -TypeDefinition $cs -ReferencedAssemblies $dll -Language CSharp
    Write-Host "Compiled."
}

# Run export

# Point the assembly resolver at the PublicAPI folder of the DLL in use, so the
# Openness version matches the project version (V17 project -> V17 API, etc.).
[Exporter]::ApiDir = (Split-Path $dll) + '\'

Write-Host "Starting export: Project=$Project  Out=$Out  Probe=$Probe  Api=$([Exporter]::ApiDir)"
[Exporter]::Run($Project, $Out, [bool]$Probe)
Write-Host "Export complete -> $Out"

