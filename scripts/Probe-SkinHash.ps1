# Derives skinbld's resource-ID hash by feeding synthetic object names through
# the 5849 skinbld.exe and reading the IDs back out of the generated header.
param(
    [string]$SkinBld = "D:\Git\RXDK\POC\XDKSetup5849.17\XDK\xbox\bin\skinbld.exe",
    [int]$MaxLen = 32,
    [string]$WorkDir = (Join-Path $env:TEMP "skprobe")
)

$ErrorActionPreference = 'Stop'
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# Characters chosen so that ('A' xor c) isolates the bit groups that occur in
# real resource names (A-Z, 0-9, underscore).
$bitProbes = [ordered]@{
    'b0'   = 'B'   # 0x03 (bits 0,1)
    'b1'   = 'C'   # 0x02
    'b2'   = 'E'   # 0x04
    'b3'   = 'I'   # 0x08
    'b4'   = 'Q'   # 0x10
    'b56'  = '1'   # 0x70 (bits 4,5,6)
}

$names = [System.Collections.Generic.List[string]]::new()

# Baselines: 'A' repeated, one per length.
for ($len = 1; $len -le $MaxLen; $len++) { $names.Add('A' * $len) }

# Single-character substitutions at every distance from the end of a fixed base.
$base = 'A' * $MaxLen
foreach ($c in $bitProbes.Values) {
    for ($pos = 0; $pos -lt $MaxLen; $pos++) {
        $chars = $base.ToCharArray()
        $chars[$MaxLen - 1 - $pos] = $c
        $names.Add(-join $chars)
    }
}

# Case sensitivity check.
$names.Add('abcdef')
$names.Add('ABCDEF')

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('[Skin]')
[void]$sb.AppendLine('Application="UIX"')
[void]$sb.AppendLine()
[void]$sb.AppendLine('[PROBE]')
[void]$sb.AppendLine('Screen.X="0"')   # skinbld requires Screen as the first object
foreach ($n in $names) { [void]$sb.AppendLine("$n.X=`"0`"") }

$inx = Join-Path $WorkDir 'probe.inx'
[IO.File]::WriteAllText($inx, $sb.ToString(), [Text.Encoding]::Unicode)

Push-Location $WorkDir
try {
    Remove-Item (Join-Path $WorkDir 'sk_res.h') -ErrorAction SilentlyContinue
    & $SkinBld /header $inx (Join-Path $WorkDir 'probe.uix') 2>&1 | ForEach-Object { "  skinbld: $_" }
} finally { Pop-Location }

$header = Join-Path $WorkDir 'sk_res.h'
if (!(Test-Path $header)) { throw "skinbld produced no header" }

$map = [ordered]@{}
foreach ($line in Get-Content $header) {
    if ($line -match '^#define\s+PROBE_(\S+)\s+0x([0-9a-fA-F]{8})') {
        $map[$matches[1]] = [uint32]('0x' + $matches[2])
    } elseif ($line -match '^#define\s+SECTION_PROBE\s+0x([0-9a-fA-F]+)') {
        $sectionId = [uint32]('0x' + $matches[1])
    }
}

"SECTION_PROBE = 0x{0:X8}" -f $sectionId
"objects: $($map.Count)"
$out = Join-Path $WorkDir 'probe-ids.txt'
$map.GetEnumerator() | ForEach-Object { "{0} 0x{1:X8}" -f $_.Key, $_.Value } | Set-Content $out
"wrote $out"
