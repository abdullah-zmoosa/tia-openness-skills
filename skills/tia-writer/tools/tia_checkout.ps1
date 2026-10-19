# tia_checkout.ps1 - copy a project folder (typically on a shared drive) to the local work area
# (TIA_WORK_ROOT, default C:\TIA_Work). The path below the drive/share root is mirrored, or the
# path below TIA_MIRROR_ANCHOR if that folder name appears in the source path:
#   X:\Machines\Line1\Software\Line1_V200          -> C:\TIA_Work\Machines\Line1\Software\Line1_V200
#   \\srv\share\Plant\Line2\Line2_V105              -> C:\TIA_Work\Plant\Line2\Line2_V105
# Records a snapshot of the source so tia_publish.ps1 can detect changes made on the share meanwhile.
#
# Usage: powershell -ExecutionPolicy Bypass -File tia_checkout.ps1 -Source <project folder> [-Force]

param(
    [Parameter(Mandatory=$true)][string]$Source,
    [switch]$Force
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

$src = (Resolve-Path $Source).Path
Assert-TiaPathRules $src 'source'
if (-not (Get-ChildItem $src -File | Where-Object { $_.Extension -match '^\.ap\d+$' })) { throw "No .apNN project file directly in $src" }
$anchor = Get-TiaMirrorAnchor
$idx = if ($anchor) { $src.IndexOf('\' + $anchor + '\', [StringComparison]::OrdinalIgnoreCase) } else { -1 }
$rel = if ($idx -ge 0) { $src.Substring($idx + $anchor.Length + 2) } else { $src.Substring([System.IO.Path]::GetPathRoot($src).Length).TrimStart('\') }
if ($src.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Refused: source is already inside the local work area: $src" }
$dst = Join-Path $workRoot $rel

if (Test-Path $dst) {
    if (-not $Force) { throw "Local copy already exists: $dst  (publish or delete it first, or use -Force to overwrite it)" }
    Remove-Item $dst -Recurse -Force
}
New-Item -ItemType Directory -Force $dst | Out-Null
"Copying $src"
"     -> $dst"
robocopy $src $dst /E /XF *.lck /R:2 /W:2 /NFL /NDL /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

$snap = Get-Snapshot $src
[pscustomobject]@{
    Source      = $src
    Local       = $dst
    CheckedOut  = (Get-Date).ToString('o')
    By          = $env:USERNAME
    SourceState = $snap
} | ConvertTo-Json | Set-Content (Join-Path $dst '.tia_checkout.json') -Encoding ascii
"Checked out: $($snap.Files) files. Work on: $dst"
