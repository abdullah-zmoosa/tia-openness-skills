# doctor.ps1 - check that this PC can run the TIA Openness skills.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '..\skills\tia-reader\tools\tia_common.ps1')
$ok = $true

function Report($name, [scriptblock]$test) {
    try {
        $r = & $test
        Write-Host ("[ OK ] {0,-28} {1}" -f $name, $r)
    } catch {
        Write-Host ("[FAIL] {0,-28} {1}" -f $name, $_.Exception.Message) -ForegroundColor Red
        $script:ok = $false
    }
}

Report 'PowerShell'            { if ($PSVersionTable.PSVersion.Major -ne 5) { "v$($PSVersionTable.PSVersion) (Windows PowerShell 5.1 is the tested target)" } else { "v$($PSVersionTable.PSVersion)" } }
Report 'TIA V20 Openness DLL'  { Get-TiaDll }
Report 'Openness user group'   { if (Test-TiaOpennessGroup) { 'member of "Siemens TIA Openness"' } else { throw 'not in "Siemens TIA Openness" (or not active in this logon - sign out/in)' } }
Report 'Python 3'              { $p = Get-TiaPython; (& $p --version 2>&1) + "  ($p)" }
Report 'Export root'           { Get-TiaExportRoot }
Report 'Work root'             { Get-TiaWorkRoot }
Report 'C# helper compiles'    {
    $dll = Get-TiaDll
    $cs  = (Get-Content (Join-Path $PSScriptRoot '..\skills\tia-reader\tools\OpennessResolver.cs') -Raw).Replace('public static class Exporter', 'public static class ExporterDoctor')
    Add-Type -TypeDefinition $cs -ReferencedAssemblies $dll -ErrorAction Stop
    'OpennessResolver.cs OK'
}

if ($ok) { Write-Host "`nAll checks passed." -ForegroundColor Green } else { Write-Host "`nFix the FAIL lines above." -ForegroundColor Yellow; exit 1 }
