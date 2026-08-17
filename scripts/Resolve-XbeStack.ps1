<#
.SYNOPSIS
Symbolizes guest addresses from a halted title against the linker's .exe.

.DESCRIPTION
Get-XemuCpuState.ps1 reports raw guest addresses; on their own they say nothing
about which function a title is sitting in. imagebld lays the XBE's code out at
a fixed offset from the .exe the linker produced, so subtracting that offset and
looking the result up in a disassembly of the .exe names the function.

The offset is derived rather than assumed: -Signature takes bytes read out of the
guest (Get-XemuCpuState's "code at eip" line) and locates them in the .exe, so a
layout change shows up as a failed match instead of a wrong answer.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Exe,
    [Parameter(Mandatory)] [string[]] $Address,
    # Hex bytes seen at $SignatureAddress in the guest, used to derive the offset.
    [string] $Signature,
    [string] $SignatureAddress,
    # Used when no signature is supplied; the offset observed for every sample so far.
    [int]    $Delta = 0x1000
)

$ErrorActionPreference = 'Stop'

function ConvertTo-UInt32([string] $s) {
    if ($s -match '^0[xX]') { return [Convert]::ToUInt32($s.Substring(2), 16) }
    return [Convert]::ToUInt32($s)
}

$bytes = [IO.File]::ReadAllBytes($Exe)

# --- derive the guest/.exe offset from the signature, when one is given -------
if ($Signature -and $SignatureAddress) {
    $pat = for ($i = 0; $i -lt $Signature.Length; $i += 2) {
        [Convert]::ToByte($Signature.Substring($i, 2), 16)
    }
    $hit = -1
    for ($i = 0; $i -le $bytes.Length - $pat.Count; $i++) {
        $match = $true
        for ($j = 0; $j -lt $pat.Count; $j++) {
            if ($bytes[$i + $j] -ne $pat[$j]) { $match = $false; break }
        }
        if ($match) { $hit = $i; break }
    }
    if ($hit -lt 0) { throw "Signature not found in $Exe - the XBE layout may have changed." }

    $pe      = [BitConverter]::ToInt32($bytes, 0x3C)
    $nsec    = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optsz   = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $imgbase = [BitConverter]::ToUInt32($bytes, $pe + 24 + 28)
    $sect    = $pe + 24 + $optsz

    $exeVa = 0
    for ($s = 0; $s -lt $nsec; $s++) {
        $o   = $sect + $s * 40
        $va  = [BitConverter]::ToUInt32($bytes, $o + 12)
        $rsz = [BitConverter]::ToUInt32($bytes, $o + 16)
        $raw = [BitConverter]::ToUInt32($bytes, $o + 20)
        if ($hit -ge $raw -and $hit -lt $raw + $rsz) { $exeVa = $imgbase + $va + ($hit - $raw) }
    }
    if (-not $exeVa) { throw "Signature landed outside every section of $Exe." }

    $Delta = (ConvertTo-UInt32 $SignatureAddress) - $exeVa
    Write-Host ("offset guest-.exe: 0x{0:X}" -f $Delta)
}

# --- disassemble once, then index the function labels by address --------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -property installationPath
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC" -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Hostx64\\x64\\|\\Hostx86\\x86\\' } | Select-Object -First 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vs." }

$asm = Join-Path $env:TEMP ((Split-Path $Exe -Leaf) + '.asm')
if (-not (Test-Path $asm) -or (Get-Item $asm).LastWriteTime -lt (Get-Item $Exe).LastWriteTime) {
    Write-Host "disassembling $(Split-Path $Exe -Leaf) ..."
    & $dumpbin.FullName /nologo /disasm:nobytes $Exe > $asm
}

$labels = New-Object System.Collections.Generic.List[object]
$current = '?'
foreach ($line in [IO.File]::ReadLines($asm)) {
    if ($line -match '^([_\?\$][^\s:]*):$') { $current = $Matches[1]; continue }
    if ($line -match '^\s*([0-9A-F]{8}):') {
        $a = [Convert]::ToUInt32($Matches[1], 16)
        if ($labels.Count -eq 0 -or $labels[$labels.Count - 1].Label -ne $current) {
            $labels.Add([pscustomobject]@{ Addr = $a; Label = $current })
        }
    }
}

foreach ($a in $Address) {
    $guest = ConvertTo-UInt32 $a
    $target = $guest - $Delta
    $best = $null
    foreach ($l in $labels) { if ($l.Addr -le $target) { $best = $l } else { break } }
    if ($best) {
        "0x{0:X8} -> {1} +0x{2:X}" -f $guest, $best.Label, ($target - $best.Addr)
    } else {
        "0x{0:X8} -> (no symbol below this address)" -f $guest
    }
}
