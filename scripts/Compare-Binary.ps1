<#
.SYNOPSIS
    Reports the differing byte ranges between two files.
.DESCRIPTION
    Used to compare a tool's output against a reference build: prints each run of
    differing bytes as offset, length and the first bytes from either side.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Reference,
    [Parameter(Mandatory)][string]$Actual,
    [int]$MaxRuns = 40,
    [int]$Context = 16
)

$a = [IO.File]::ReadAllBytes((Resolve-Path $Reference))
$b = [IO.File]::ReadAllBytes((Resolve-Path $Actual))

Write-Host ("reference {0} bytes, actual {1} bytes" -f $a.Length, $b.Length)

$common = [Math]::Min($a.Length, $b.Length)
$runs = 0
$i = 0
$total = 0

while ($i -lt $common) {
    if ($a[$i] -eq $b[$i]) { $i++; continue }

    $start = $i
    while ($i -lt $common -and $a[$i] -ne $b[$i]) { $i++ }
    $length = $i - $start
    $total += $length
    $runs++

    if ($runs -le $MaxRuns) {
        $n = [Math]::Min($Context, $length)
        $refHex = ($a[$start..($start + $n - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
        $actHex = ($b[$start..($start + $n - 1)] | ForEach-Object { $_.ToString('x2') }) -join ' '
        Write-Host ("0x{0:x8}  len {1,-8} ref {2}" -f $start, $length, $refHex)
        Write-Host ("{0,-12}  {1,-12} act {2}" -f '', '', $actHex)
    }
}

Write-Host ("{0} differing runs, {1} bytes total" -f $runs, $total)
