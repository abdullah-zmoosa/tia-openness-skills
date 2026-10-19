# tia_write.ps1 - import edited blocks/UDTs/tag tables/SCL into a local copy of a TIA V20 project.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tia_write.ps1 -Project <local X.ap20 or its folder> `
#       -Files <a.scl>,<b.xml> [-Group "Folder/Sub"] [-DryRun]
#
# Guards (hard):
#   - only .ap20 (V20) projects - no upgrade on write
#   - path must be under the local work area (TIA_WORK_ROOT, default C:\TIA_Work - a copy made by
#     tia_checkout.ps1); optional TIA_REQUIRE_SEGMENT / TIA_PROTECTED_SEGMENTS folder rules.
#     The shared copy is never written directly (tia_publish.ps1 does that, on request)
#   - safety (F_) and know-how-protected blocks are refused
#   - whole project folder is zipped to <TIA_EXPORT_ROOT>\_backups first
#   - saved ONLY if every import succeeds and the compile has 0 errors
#   - never downloads to a PLC
# Project must be CLOSED in the TIA UI.

param(
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string[]]$Files,
    [string]$Group = "",
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tia_common.ps1"
$root = Get-TiaExportRoot
$workRoot = Get-TiaWorkRoot
$log  = Join-Path $root ('_write_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
New-Item -ItemType Directory -Force $root | Out-Null
Start-Transcript -Path $log -Force | Out-Null
$code = 3
try {
    # Resolve project file
    if (Test-Path $Project -PathType Container) {
        $f = Get-ChildItem $Project -File | Where-Object { $_.Extension -match '^\.ap\d+$' } | Select-Object -First 1
        if (-not $f) { throw "No .apNN file in folder: $Project" }
        $Project = $f.FullName
    }
    if (-not (Test-Path $Project)) { throw "Project not found: $Project" }
    $pf = Get-Item $Project

    # Guards
    if ($pf.Extension -ne '.ap20') { throw "Refused: write only supports V20 (.ap20) projects, got $($pf.Extension)" }
    $full = $pf.FullName
    if (-not $full.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refused: write only into the local work area $workRoot (check out from the share with tia_checkout.ps1 first): $full"
    }
    Assert-TiaPathRules $full 'project'
    if (Get-ChildItem $pf.Directory.FullName -Recurse -Filter *.lck -ErrorAction SilentlyContinue) {
        Write-Warning "Lock files found - the project may be open in TIA. Close it in TIA first if the open fails."
    }
    $resolved = @()
    foreach ($x in $Files) {
        foreach ($y in ($x -split ',')) {
            if ($y.Trim()) {
                if (-not (Test-Path $y.Trim())) { throw "Import file not found: $y" }
                $resolved += (Resolve-Path $y.Trim()).Path
            }
        }
    }
    if (-not (Test-TiaOpennessGroup)) { Write-Warning "Openness group missing in this logon - open will be refused." }

    "Project : $full"
    "Files   : $($resolved -join '; ')"
    "Group   : $Group"
    "DryRun  : $DryRun"

    # Backup (skip for dry runs - nothing is saved)
    if (-not $DryRun) {
        $bdir = Join-Path $root '_backups'
        New-Item -ItemType Directory -Force $bdir | Out-Null
        $zip = Join-Path $bdir ($pf.BaseName + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
        "Backing up project folder to $zip ..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($pf.Directory.FullName, $zip)
        "Backup OK ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)"
    }

    $dll = Get-TiaDll
    if (-not ([System.Management.Automation.PSTypeName]'TiaWriter').Type) {
        Add-Type -TypeDefinition (Get-Content "$PSScriptRoot\TiaWriter.cs" -Raw) -ReferencedAssemblies $dll, 'System.Xml' -Language CSharp
    }
    [TiaWriter]::ApiDir = (Split-Path $dll) + '\'
    $code = [TiaWriter]::Run($full, $resolved, $Group, [bool]$DryRun)
}
catch {
    "=== FAILED === $($_.Exception.Message)"
}
finally {
    "Exit code: $code  (0 saved, 1 not saved: compile errors/dry run, 2 import failed, 3 error before import)"
    "Log: $log"
    Stop-Transcript | Out-Null
}
exit $code
