# test_static.ps1 - checks that need no TIA Portal (run locally or in CI).
#   - every .ps1 parses under Windows PowerShell 5.1
#   - .ps1/.cs files are ASCII only (PS 5.1 misreads UTF-8 without BOM)
#   - the two tia_common.ps1 copies are identical
#   - tia-writer refuses: shared paths, non-.ap20, protected folders, required-segment rule
# Usage: powershell -ExecutionPolicy Bypass -File tests\test_static.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Check($name, [bool]$cond, $detail) {
    if ($cond) { Write-Host "[PASS] $name" }
    else { Write-Host "[FAIL] $name  $detail" -ForegroundColor Red; $script:fail++ }
}

# 1. parse
foreach ($f in Get-ChildItem $root -Recurse -Filter *.ps1) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    Check "parse $($f.Name)" ($errs.Count -eq 0) ($errs | ForEach-Object { $_.Message })
}

# 2. ASCII
foreach ($f in Get-ChildItem $root -Recurse -Include *.ps1, *.cs) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $bad = @($bytes | Where-Object { $_ -gt 127 }).Count
    Check "ascii $($f.Name)" ($bad -eq 0) "$bad non-ASCII bytes"
}

# 3. helper copies identical
$a = Get-FileHash (Join-Path $root 'skills\tia-reader\tools\tia_common.ps1')
$b = Get-FileHash (Join-Path $root 'skills\tia-writer\tools\tia_common.ps1')
Check 'tia_common.ps1 copies identical' ($a.Hash -eq $b.Hash) 'reader and writer copies differ'

# 4. writer guards (dummy files, refused before TIA is ever started)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('tiatest_' + [guid]::NewGuid().ToString('N'))
$work = Join-Path $tmp 'work'
$share = Join-Path $tmp 'share'
foreach ($d in "$work\Line\Working\P", "$work\Line\Master\P", "$work\Line\Other\P", "$work\Line\Working\Q", "$share\P") {
    New-Item -ItemType Directory -Force $d | Out-Null
}
'x' | Set-Content "$work\Line\Working\P\P.ap20"; 'x' | Set-Content "$work\Line\Master\P\P.ap20"
'x' | Set-Content "$work\Line\Other\P\P.ap20";   'x' | Set-Content "$work\Line\Working\Q\Q.ap17"
'x' | Set-Content "$share\P\P.ap20";             'x' | Set-Content "$tmp\x.scl"
$writer = Join-Path $root 'skills\tia-writer\tools\tia_write.ps1'

function Invoke-Writer($project, $env) {
    $saved = @{}
    foreach ($k in $env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $env[$k]) }
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $writer -Project $project -Files "$tmp\x.scl" 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

$base = @{ TIA_WORK_ROOT = $work; TIA_EXPORT_ROOT = "$tmp\exports"; TIA_REQUIRE_SEGMENT = $null; TIA_PROTECTED_SEGMENTS = $null }
$r = Invoke-Writer "$share\P" $base
Check 'writer refuses path outside work root' ($r.Code -eq 3 -and $r.Out -match 'local work area') $r.Out
$r = Invoke-Writer "$work\Line\Working\Q" $base
Check 'writer refuses non-.ap20' ($r.Code -eq 3 -and $r.Out -match '\.ap20') $r.Out
$r = Invoke-Writer "$work\Line\Master\P" $base
Check 'writer refuses protected folder (default Master)' ($r.Code -eq 3 -and $r.Out -match 'protected') $r.Out
$e = $base.Clone(); $e.TIA_REQUIRE_SEGMENT = 'Working'
$r = Invoke-Writer "$work\Line\Other\P" $e
Check 'writer enforces TIA_REQUIRE_SEGMENT' ($r.Code -eq 3 -and $r.Out -match 'TIA_REQUIRE_SEGMENT') $r.Out
$e = $base.Clone(); $e.TIA_PROTECTED_SEGMENTS = 'Other'
$r = Invoke-Writer "$work\Line\Other\P" $e
Check 'writer honours custom TIA_PROTECTED_SEGMENTS' ($r.Code -eq 3 -and $r.Out -match 'protected') $r.Out

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { Write-Host "`n$fail check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll static checks passed" -ForegroundColor Green
