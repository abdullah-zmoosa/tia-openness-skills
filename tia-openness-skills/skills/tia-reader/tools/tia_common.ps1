# tia_common.ps1 - shared helpers (dot-source it). No user- or site-specific paths:
# everything is auto-detected, and can be overridden with environment variables:
#   TIA_OPENNESS_DLL        full path to Siemens.Engineering.dll (V20)
#   TIA_EXPORT_ROOT         where read exports, logs and backups go  (default %USERPROFILE%\TIA_Exports)
#   TIA_WORK_ROOT           local work area for writes               (default C:\TIA_Work)
#   TIA_PYTHON              python.exe to use
#   TIA_REQUIRE_SEGMENT     writer/checkout only accept project paths containing \<this>\  (e.g. Working; default: none)
#   TIA_PROTECTED_SEGMENTS  ;-separated folder names the writer/publisher never touch       (default Master;Archive)
#   TIA_MIRROR_ANCHOR       checkout mirrors the path below \<this>\ if present             (default: none = below drive/share root)

function Get-TiaDll {
    if ($env:TIA_OPENNESS_DLL -and (Test-Path $env:TIA_OPENNESS_DLL)) { return $env:TIA_OPENNESS_DLL }
    # TIA V20 registers its Openness API here, wherever it is installed
    foreach ($k in 'HKLM:\SOFTWARE\Siemens\Automation\Openness\20.0\PublicAPI\20.0.0.0',
                   'HKLM:\SOFTWARE\WOW6432Node\Siemens\Automation\Openness\20.0\PublicAPI\20.0.0.0') {
        try {
            $p = (Get-ItemProperty $k -ErrorAction Stop).'Siemens.Engineering'
            if ($p -and (Test-Path $p)) { return $p }
        } catch { }
    }
    $p = "$env:ProgramFiles\Siemens\Automation\Portal V20\PublicAPI\V20\Siemens.Engineering.dll"
    if (Test-Path $p) { return $p }
    throw 'TIA Portal V20 Openness not found (install TIA V20 with Openness, or set TIA_OPENNESS_DLL)'
}

function Get-TiaPython {
    if ($env:TIA_PYTHON -and (Test-Path $env:TIA_PYTHON)) { return $env:TIA_PYTHON }
    foreach ($c in 'python', 'python3') {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        # skip the Microsoft Store stub (WindowsApps), it only opens the Store
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { return $cmd.Source }
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $exe = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
        if ($exe -and (Test-Path $exe)) { return $exe }
    }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw 'Python 3 not found (install it, or set TIA_PYTHON)'
}

function Get-TiaExportRoot {
    if ($env:TIA_EXPORT_ROOT) { return $env:TIA_EXPORT_ROOT }
    return (Join-Path $env:USERPROFILE 'TIA_Exports')
}

function Get-TiaWorkRoot {
    if ($env:TIA_WORK_ROOT) { return $env:TIA_WORK_ROOT.TrimEnd('\') }
    return 'C:\TIA_Work'
}

function Get-TiaRequiredSegment {
    if ($env:TIA_REQUIRE_SEGMENT) { return $env:TIA_REQUIRE_SEGMENT.Trim('\') }
    return ''
}

function Get-TiaProtectedSegments {
    $v = if ($null -ne $env:TIA_PROTECTED_SEGMENTS) { $env:TIA_PROTECTED_SEGMENTS } else { 'Master;Archive' }
    return @($v -split ';' | ForEach-Object { $_.Trim('\', ' ') } | Where-Object { $_ })
}

# Throws if the path breaks the required / protected folder rules
function Assert-TiaPathRules([string]$Path, [string]$What) {
    $req = Get-TiaRequiredSegment
    if ($req -and ($Path -notmatch ('\\' + [regex]::Escape($req) + '\\'))) {
        throw "Refused: $What is not under a \$req\ folder (TIA_REQUIRE_SEGMENT): $Path"
    }
    foreach ($s in Get-TiaProtectedSegments) {
        if ($Path -match ('\\' + [regex]::Escape($s) + '\\')) {
            throw "Refused: $What is under a protected \$s\ folder (TIA_PROTECTED_SEGMENTS): $Path"
        }
    }
}

function Get-TiaMirrorAnchor {
    if ($env:TIA_MIRROR_ANCHOR) { return $env:TIA_MIRROR_ANCHOR.Trim('\') }
    return ''
}

# Mapped drive letter -> UNC path (runas / other logon sessions don't have mapped drives)
function ConvertTo-TiaUncPath([string]$Path) {
    if ($Path -match '^([A-Za-z]):\\(.*)$') {
        $letter = $Matches[1]; $rest = $Matches[2]
        $d = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($d -and $d.DisplayRoot -and $d.DisplayRoot.StartsWith('\\')) {
            return ($d.DisplayRoot.TrimEnd('\') + '\' + $rest)
        }
        try {
            $remote = (Get-CimInstance Win32_MappedLogicalDisk -Filter "DeviceID='${letter}:'" -ErrorAction Stop).ProviderName
            if ($remote) { return ($remote.TrimEnd('\') + '\' + $rest) }
        } catch { }
    }
    return $Path
}

function Test-TiaOpennessGroup {
    return [bool]((whoami /groups) -match 'Siemens TIA Openness')
}
