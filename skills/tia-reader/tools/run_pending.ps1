# run_pending.ps1 - fixed entry point for runas (no quoting problems).
# Claude writes one project path per line (UNC, not mapped drive letters - runas
# sessions don't have X: etc.) to %USERPROFILE%\TIA_Exports\PENDING.txt; this exports each.
. "$PSScriptRoot\tia_common.ps1"
$pending = Join-Path (Get-TiaExportRoot) 'PENDING.txt'
if (-not (Test-Path $pending)) { Write-Host "Nothing pending ($pending missing)"; Read-Host 'Press Enter'; exit }
$projects = Get-Content $pending | Where-Object { $_.Trim() }
foreach ($p in $projects) {
    Write-Host "`n##### $p"
    & "$PSScriptRoot\tia_read.ps1" -Project $p.Trim()
}
Remove-Item $pending -Force
Read-Host "`nAll done - press Enter to close"
