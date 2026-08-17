# Compiles an .inx body with the 5849 skinbld.exe and dumps the resulting .uix,
# so container details can be observed directly. Used to develop Rxdk.SkinBld.
param(
    [Parameter(Mandatory = $true)][string]$BodyFile,
    [string]$SkinBld = "D:\Git\RXDK\POC\XDKSetup5849.17\XDK\xbox\bin\skinbld.exe",
    [string]$WorkDir = (Join-Path $env:TEMP "skinprobe"),
    [switch]$Header
)

$ErrorActionPreference = 'Stop'
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }
$inx = Join-Path $WorkDir 'probe.inx'
$uix = Join-Path $WorkDir 'probe.uix'
[IO.File]::WriteAllText($inx, [IO.File]::ReadAllText($BodyFile), [Text.Encoding]::Unicode)

Remove-Item $uix -ErrorAction SilentlyContinue
Push-Location $WorkDir
try {
    $args = @()
    if ($Header) { $args += '/header' }
    $args += @($inx, $uix)
    & $SkinBld @args 2>&1 | Where-Object { $_ -notmatch 'Copyright|^\s*$|Xbox Skin Builder' } | ForEach-Object { "  skinbld: $_" }
} finally { Pop-Location }

if (Test-Path $uix) { python (Join-Path $PSScriptRoot '..\..\RXDK-VS20XX\scripts\uixdump.py') $uix }
