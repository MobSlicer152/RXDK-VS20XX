<#
.SYNOPSIS
Re-reads the serial logs captured by Invoke-SampleRunSweep and produces the per-sample verdict.

.DESCRIPTION
Kept separate from the sweep so the classification can be revised without spending another
hour booting every title. The sweep's own live status is deliberately coarse; this is where
a log is read for what actually went wrong - a bugcheck, a named missing file, or a title
that never handed control to the framework at all.
#>
[CmdletBinding()]
param(
    [string] $OutDir = "$env:TEMP\rxdk-runsweep"
)

$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;

public class Frame {
    // 32x32 grey thumbnail: enough to tell "still the BIOS logo" from "a rendered scene",
    // and immune to the logo's slow pulse and to resolution differences between titles.
    public static byte[] Print(string path) {
        using (Bitmap src = new Bitmap(path))
        using (Bitmap small = new Bitmap(32, 32)) {
            using (Graphics g = Graphics.FromImage(small)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                // crop off the window chrome before scaling
                int top = src.Height / 8;
                g.DrawImage(src, new Rectangle(0, 0, 32, 32),
                            new Rectangle(0, top, src.Width, src.Height - top), GraphicsUnit.Pixel);
            }
            byte[] o = new byte[1024];
            for (int y = 0; y < 32; y++)
                for (int x = 0; x < 32; x++) {
                    Color c = small.GetPixel(x, y);
                    o[y * 32 + x] = (byte)((c.R * 30 + c.G * 59 + c.B * 11) / 100);
                }
            return o;
        }
    }

    public static double Diff(byte[] a, byte[] b) {
        long s = 0;
        for (int i = 0; i < a.Length; i++) s += Math.Abs(a[i] - b[i]);
        return (double)s / a.Length;
    }
}
'@

$csv = Join-Path $OutDir 'results.csv'
$frozen = @{}
if (Test-Path $csv) {
    foreach ($row in Import-Csv $csv) { $frozen[$row.Sample] = ($row.Frozen -eq 'True') }
}

# the last attempt is the one the sweep judged, earlier ones are retries
$bySample = @{}
foreach ($f in Get-ChildItem $OutDir -Filter '*.log') {
    if ($f.Name -notmatch '^(.*)\.a(\d+)\.log$') { continue }
    $name = $Matches[1]; $n = [int]$Matches[2]
    if (-not $bySample.ContainsKey($name) -or $n -gt $bySample[$name].N) {
        $bySample[$name] = [pscustomobject]@{ N = $n; Path = $f.FullName }
    }
}

$shotBySample = @{}
foreach ($f in Get-ChildItem $OutDir -Filter '*.png') {
    if ($f.Name -notmatch '^(.*)\.a(\d+)\.png$') { continue }
    $name = $Matches[1]; $n = [int]$Matches[2]
    if (-not $shotBySample.ContainsKey($name) -or $n -gt $shotBySample[$name].N) {
        $shotBySample[$name] = [pscustomobject]@{ N = $n; Path = $f.FullName }
    }
}

$rows = @(foreach ($name in ($bySample.Keys | Sort-Object)) {
    $t = Get-Content $bySample[$name].Path -Raw
    if (-not $t) { $t = '' }

    $missing = ([regex]::Matches($t, 'Could not find file \[([^\]]+)\]') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)

    # the last thing the framework announced before it died tells us which phase failed
    $stage = ''
    $stages = [regex]::Matches($t, 'XBApp: ([^\r\n]+)')
    if ($stages.Count) { $stage = $stages[$stages.Count - 1].Groups[1].Value.TrimEnd('.') }

    $verdict = 'UNKNOWN'; $detail = ''
    if ($t -match 'Fatal System Error: (0x[0-9a-fA-F]+)') {
        $verdict = 'CRASHED'
        $detail = "bugcheck $($Matches[1]) during '$stage'"
    }
    elseif ($t -match 'XBApp: Call to Initialize\(\) failed') {
        $verdict = 'INIT FAILED'
        $detail = if ($missing) { "missing: $($missing -join ', ')" } else { "failed at '$stage'" }
    }
    elseif ($t -match 'XBApp: Running the application') {
        $verdict = 'RUNS'
        if ($missing) { $detail = "runs, but missing: $($missing -join ', ')" }
        elseif ($frozen[$name]) { $detail = 'frame never changed' }
    }
    elseif ($t -match 'SAMPLE: [^\r\n]*FAILED at ([^\r\n]+?)(?:\s*-|\r|\n|$)') {
        # A non-framework sample emitted its own diagnostic marker naming the phase it
        # died in (see the SAMPLE: convention in the tutorial/online samples).
        $verdict = 'INIT FAILED'
        $detail = if ($missing) { "missing: $($missing -join ', ')" } else { "failed at $($Matches[1].Trim())" }
    }
    elseif ($t -match 'SAMPLE: [^\r\n]*:\s*exit') {
        # A console/test sample ran its work and exited cleanly - not a hang.
        $verdict = 'COMPLETED'
        $detail = 'ran to completion and exited'
    }
    elseif ($t -match 'SAMPLE: [^\r\n]*:\s*render loop') {
        # A non-framework sample confirmed it reached its render loop.
        $verdict = 'RUNS'
        if ($missing) { $detail = "runs, but missing: $($missing -join ', ')" }
        elseif ($frozen[$name]) { $detail = 'frame never changed' }
        else { $detail = 'running (no XBApp framework)' }
    }
    elseif ($t -match 'RXDK\.start: main') {
        # no framework trace at all: either a title that does not use XBApp, or one that
        # wedged before saying anything. The screenshot is what separates the two.
        if ($frozen.ContainsKey($name) -and -not $frozen[$name]) {
            $verdict = 'RUNS (no framework)'
        } else {
            $verdict = 'HUNG IN MAIN'
        }
    }
    elseif ($t -match 'XeLoadTitleImge status2 = (?!00000000)([0-9A-Fa-f]{8})') {
        # the kernel refused the XBE and the BIOS fell back to the dashboard, which puts up
        # "your Xbox can't recognize this disc" - the disc is fine, the title would not load
        $code = $Matches[1].ToUpper()
        $verdict = 'WILL NOT LOAD'
        $detail = if ($code -eq 'C0000135') {
            'STATUS_DLL_NOT_FOUND - imports XBDM.DLL, which only exists on a devkit'
        } else {
            "kernel rejected the XBE, status $code"
        }
    }
    elseif ($t) { $verdict = 'NO BOOT'; $detail = 'BIOS ran, title never started' }
    else { $verdict = 'NO SERIAL OUTPUT' }

    if ($verdict -eq 'RUNS' -and $frozen[$name]) { $verdict = 'RUNS (frozen)' }

    [pscustomobject]@{
        Sample  = $name
        Verdict = $verdict
        Stage   = $stage
        Missing = ($missing -join ', ')
        Detail  = $detail
        Screen  = ''
        Shot    = if ($shotBySample.ContainsKey($name)) { $shotBySample[$name].Path } else { '' }
    }
})

# Most titles that failed never presented a frame, so the BIOS logo is still up - but some
# clear to black first, so any single one of them is a poor reference. Take the frame the
# most failures agree on instead, which is the logo by weight of numbers.
$prints = @{}
foreach ($row in $rows) {
    if (-not $row.Shot) { continue }
    try { $prints[$row.Sample] = [Frame]::Print($row.Shot) } catch { }
}

$ref = $null
$failed = @($rows | Where-Object { $_.Verdict -in 'INIT FAILED', 'CRASHED' -and $prints.ContainsKey($_.Sample) })
$best = -1
foreach ($a in $failed) {
    $n = 0
    foreach ($b in $failed) {
        if ([Frame]::Diff($prints[$a.Sample], $prints[$b.Sample]) -lt 6) { $n++ }
    }
    if ($n -gt $best) { $best = $n; $ref = $prints[$a.Sample] }
}
if ($best -lt 3) { $ref = $null }

if ($ref) {
    foreach ($row in $rows) {
        if (-not $prints.ContainsKey($row.Sample)) { continue }
        $row.Screen = if ([Frame]::Diff($ref, $prints[$row.Sample]) -lt 6) { 'bios logo' } else { 'rendered' }
    }
    foreach ($row in $rows) {
        if ($row.Verdict -ne 'HUNG IN MAIN') { continue }
        if ($row.Screen -eq 'rendered') {
            $row.Verdict = 'RUNS (no framework)'
            $row.Detail  = 'static scene, no framework trace'
        } else {
            $row.Detail = 'never drew a frame'
        }
    }
}

$rows | Export-Csv (Join-Path $OutDir 'report.csv') -NoTypeInformation

$order = 'RUNS', 'RUNS (no framework)', 'RUNS (frozen)', 'COMPLETED', 'INIT FAILED', 'CRASHED', 'HUNG IN MAIN', 'WILL NOT LOAD', 'NO BOOT', 'NO SERIAL OUTPUT'
'==== verdicts ===='
foreach ($v in $order) {
    $c = ($rows | Where-Object Verdict -eq $v | Measure-Object).Count
    if ($c) { "{0,-22} {1}" -f $v, $c }
}
"{0,-22} {1}" -f 'TOTAL', $rows.Count
''
foreach ($v in $order) {
    $set = $rows | Where-Object Verdict -eq $v
    if (-not $set) { continue }
    "---- $v ($($set.Count)) ----"
    $set | ForEach-Object { "  {0,-26} {1}" -f $_.Sample, $_.Detail }
    ''
}
"report: $(Join-Path $OutDir 'report.csv')"
