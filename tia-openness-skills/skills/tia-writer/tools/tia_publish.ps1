# tia_publish.ps1 - copy a finished local project (<TIA_WORK_ROOT>\...) back to the shared
# folder it was checked out from. ONLY run when the user explicitly says to publish / move it back.
#
#   - refuses if the shared copy changed since checkout (someone else saved) unless -Force
#   - zips the current shared folder to <TIA_EXPORT_ROOT>\_backups first
#   - mirrors local -> share (robocopy /MIR: files deleted locally are deleted there, backup covers it)
#   - TIA must be closed on both copies
#
# Usage: powershell -ExecutionPolicy Bypass -File tia_publish.ps1 -Local <local project folder> [-Check] [-Force]

param(
    [Parameter(Mandatory=$true)][string]$Local,
    [switch]$Force,
    [switch]$Check   # report only: would a publish be allowed? copies nothing
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tia_common.ps1"
$workRoot = Get-TiaWorkRoot

function Get-Snapshot($dir) {
    $files = Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.lck' -and $_.Name -ne '.tia_checkout.json' }
    $newest = ($files | Measure-Object LastWriteTimeUtc -Maximum).Maximum
    [pscustomobject]@{
        Files  = $files.Count
        Bytes  = ($files | Measure-Object Length -Sum).Sum
        Newest = if ($newest) { $newest.ToString('o') } else { '' }
    }
}

$loc = (Resolve-Path $Local).Path
if (-not $loc.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Refused: -Local must be under $workRoot" }
$meta = Join-Path $loc '.tia_checkout.json'
if (-not (Test-Path $meta)) { throw "No .tia_checkout.json in $loc - not a checked-out project" }
$co  = Get-Content $meta -Raw | ConvertFrom-Json
$dst = $co.Source
Assert-TiaPathRules $dst 'publish target'
if (-not (Test-Path $dst)) { throw "Shared target missing: $dst" }
if (Get-ChildItem $loc, $dst -Recurse -Filter *.lck -ErrorAction SilentlyContinue) { throw "Lock files found - close the project in TIA (local and shared copy) first" }

$now = Get-Snapshot $dst
$then = $co.SourceState
$changed = ($now.Files -ne $then.Files -or $now.Bytes -ne $then.Bytes -or $now.Newest -ne $then.Newest)
if ($Check) {
    "Local : $loc"
    "Share : $dst"
    if ($changed) { "Shared copy CHANGED since checkout ($($co.CheckedOut)) - publish would be refused" }
    else { "Shared copy unchanged since checkout - publish allowed" }
    return
}
if ($changed -and -not $Force) {
    throw "Refused: the shared copy changed since checkout ($($co.CheckedOut)). Someone may have saved it. Check before overwriting; use -Force only with the user's OK."
}

$bdir = Join-Path (Get-TiaExportRoot) '_backups'
New-Item -ItemType Directory -Force $bdir | Out-Null
$zip = Join-Path $bdir ((Split-Path $dst -Leaf) + '_share_before_publish_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
"Backing up shared copy to $zip ..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($dst, $zip)

"Publishing $loc"
"        -> $dst"
robocopy $loc $dst /MIR /XF *.lck .tia_checkout.json /R:2 /W:2 /NFL /NDL /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE) - restore from $zip if needed" }

# New baseline so further local work can be published again
$co.SourceState = Get-Snapshot $dst
$co | Add-Member -NotePropertyName LastPublished -NotePropertyValue (Get-Date).ToString('o') -Force
$co | ConvertTo-Json | Set-Content $meta -Encoding ascii
"PUBLISHED. Backup of previous shared copy: $zip"
