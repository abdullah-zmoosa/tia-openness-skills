# tia_source.ps1 - generate FULL SCL / DB / UDT source for named blocks, ready to edit + import.
# Runs on a tia-reader COPY (...TIA_Exports\<export>\_src\...), never the real project. Never saves.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tia_source.ps1 -Export <TIA_Exports\<export folder>> -Blocks "FB_X","DB_Y" [-Out <dir>]

param(
    [Parameter(Mandatory=$true)][string]$Export,
    [Parameter(Mandatory=$true)][string[]]$Blocks,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\tia_common.ps1"
$root = Get-TiaExportRoot
$full = (Resolve-Path $Export).Path
if (-not $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Refused: -Export must be a tia-reader export folder under $root" }
# Prefer the compiled V20 copy (an upgraded *_V20 folder if the original was older)
$ap = Get-ChildItem (Join-Path $full '_src') -Recurse -Filter *.ap20 -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ap) { throw "No .ap20 copy under $full\_src (re-run tia-reader on the project first)" }
if (-not $Out) { $Out = Join-Path $full 'edit' }
$names = @(); foreach ($b in $Blocks) { $names += ($b -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }

$dll = Get-TiaDll
if (-not ([System.Management.Automation.PSTypeName]'TiaWriter').Type) {
    Add-Type -TypeDefinition (Get-Content "$PSScriptRoot\TiaWriter.cs" -Raw) -ReferencedAssemblies $dll, 'System.Xml' -Language CSharp
}
[TiaWriter]::ApiDir = (Split-Path $dll) + '\'
"Copy    : $($ap.FullName)"
"Out     : $Out"
$bad = [TiaWriter]::GenerateSources($ap.FullName, $names, $Out)
exit $bad
