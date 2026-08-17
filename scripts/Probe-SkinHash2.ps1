# Second-round probe: measures skinbld's resource-ID hash for every legal name
# character at every position, plus a random validation set.
param(
    [string]$SkinBld = "D:\Git\RXDK\POC\XDKSetup5849.17\XDK\xbox\bin\skinbld.exe",
    [string]$WorkDir = (Join-Path $env:TEMP "skprobe2")
)

$ErrorActionPreference = 'Stop'
if (!(Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

$alpha = [char[]](([char]'A'..[char]'Z') + ([char]'0'..[char]'9') + [char]'_')
$names = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new()
function Add-Name([string]$n) { if ($seen.Add($n)) { $names.Add($n) } }

# Group A: each character at each distance from the end of a 32-char base.
$len = 32
$base = 'A' * $len
foreach ($c in $alpha) {
    for ($d = 0; $d -lt 18; $d++) {
        $arr = $base.ToCharArray(); $arr[$len - 1 - $d] = $c
        Add-Name (-join $arr)
    }
}

# Group B: single characters, and runs of one character at every length.
foreach ($c in $alpha) { Add-Name ([string]$c) }
for ($L = 1; $L -le 20; $L++) { Add-Name ('B' * $L); Add-Name ('Z' * $L) }

# Group C: two simultaneous substitutions, to test whether contributions XOR.
foreach ($d1 in 0, 1, 3, 7, 12) {
    foreach ($d2 in 2, 5, 9, 15) {
        $arr = $base.ToCharArray()
        $arr[$len - 1 - $d1] = 'Q'; $arr[$len - 1 - $d2] = 'E'
        Add-Name (-join $arr)
    }
}

# Group D: random validation names.
$rand = [Random]::new(1234)
for ($i = 0; $i -lt 64; $i++) {
    $L = 3 + $rand.Next(20)
    $sb2 = [Text.StringBuilder]::new()
    for ($k = 0; $k -lt $L; $k++) { [void]$sb2.Append($alpha[$rand.Next($alpha.Length)]) }
    $n = $sb2.ToString()
    if ($n -match '^[0-9_]') { $n = 'V' + $n }
    Add-Name $n
}

$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine('[Skin]')
[void]$sb.AppendLine('Application="UIX"')
[void]$sb.AppendLine()
[void]$sb.AppendLine('[PROBE]')
[void]$sb.AppendLine('Screen.X="0"')
foreach ($n in $names) { [void]$sb.AppendLine("$n.X=`"0`"") }

$inx = Join-Path $WorkDir 'probe.inx'
[IO.File]::WriteAllText($inx, $sb.ToString(), [Text.Encoding]::Unicode)
"probe names: $($names.Count)"

Push-Location $WorkDir
try {
    Remove-Item (Join-Path $WorkDir 'sk_res.h') -ErrorAction SilentlyContinue
    & $SkinBld /header $inx (Join-Path $WorkDir 'probe.uix') 2>&1 | ForEach-Object { "  skinbld: $_" }
} finally { Pop-Location }

$out = Join-Path $WorkDir 'probe-ids.txt'
$lines = [System.Collections.Generic.List[string]]::new()
foreach ($line in Get-Content (Join-Path $WorkDir 'sk_res.h')) {
    if ($line -match '^#define\s+PROBE_(\S+)\s+0x([0-9a-fA-F]{8})') {
        $lines.Add("$($matches[1]) $($matches[2])")
    }
}
$lines | Set-Content $out
"ids captured: $($lines.Count) -> $out"
