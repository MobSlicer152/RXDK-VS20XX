<#
.SYNOPSIS
Boots every built sample ISO in xemu and catalogs whether it reaches its render loop.

.DESCRIPTION
Building clean says nothing about whether a title runs - most failures here are media the
game asks for by name at runtime. This boots each ISO, captures the serial log and a
screenshot of the final frame, and classifies the outcome from the shared framework's trace.

A sample that never gets past the BIOS logo is a failure even though the emulator is happily
running, so the serial trace alone is not enough - the screenshot is the evidence for
anything that does not reach its render loop.

Runs are sequential: xemu opens the shared HDD image with locked=on, so a second instance -
or one started before the previous has released its handles - dies at startup having written
nothing. That looks exactly like a broken sample, so launch failures are detected from
xemu's own stderr and retried rather than blamed on the title.

Headless is not an option - '-display none' hangs the title before main and 'egl-headless'
does not start, so a window will appear and disappear for each sample.

.PARAMETER TimeoutSeconds
Upper bound on the first attempt at a sample. A sample that gives no clear verdict is retried
once with twice this budget, so a slow boot costs time only where it actually happens.

.PARAMETER GraceSeconds
How long to keep watching after the title reaches its render loop, to catch a late crash.
#>
[CmdletBinding()]
param(
    [string] $Root,
    [string] $XemuDir = "D:\Git\xemu-devkit",
    [string] $Configuration = 'Debug',
    [int]    $TimeoutSeconds = 10,
    [int]    $GraceSeconds = 2,
    [string] $OutDir = "$env:TEMP\rxdk-runsweep",
    [string[]] $Only
)

$ErrorActionPreference = 'Stop'

if (-not $Root) {
    $self = if ($PSCommandPath) { $PSCommandPath } elseif ($PSScriptRoot) { Join-Path $PSScriptRoot 'x' } else { $null }
    if ($self) { $Root = Split-Path -Parent (Split-Path -Parent $self) }
}
if (-not $Root) { $Root = (Get-Location).Path }
$Root = (Resolve-Path -LiteralPath $Root).Path
if (-not (Test-Path (Join-Path $Root 'XDKSamples'))) {
    throw "No XDKSamples under $Root - pass -Root explicitly."
}

$xemu = Join-Path $XemuDir 'xemu.exe'
if (-not (Test-Path $xemu)) { throw "xemu not found at $xemu" }

Add-Type -ReferencedAssemblies System.Drawing, System -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;

public class XemuShot {
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] static extern bool IsHungAppWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

    // True when the last grab had to scrape the window because xemu could not be
    // brought to the foreground. A scrape of an occluded GPU-composited window comes
    // back all black, which is indistinguishable from a title that never drew, so
    // the caller has to know the difference rather than trust the pixels.
    public static bool LastGrabWasScrape = false;

    // Sticky across the grabs taken for one title, so a verdict can say the pixels are
    // not trustworthy rather than reporting an occluded window as an unlit screen.
    public static bool AnyGrabWasScrape = false;

    public static void ResetScrape() { LastGrabWasScrape = false; AnyGrabWasScrape = false; }

    // Every way of photographing a window is synchronous against the window's own message
    // queue, so an emulator whose UI thread stops pumping blocks the grab with no timeout and
    // takes the whole sweep down with it. Two defences: refuse to photograph a window Windows
    // already considers hung, and keep a thread armed that kills the process once its wall
    // clock is spent. Killing it is what releases a grab that is already blocked.
    static int killGeneration = 0;
    public static bool KillFired = false;

    public static bool WindowHung(IntPtr h) { return IsHungAppWindow(h); }

    public static void ArmKill(int pid, int seconds) {
        int mine = Interlocked.Increment(ref killGeneration);
        KillFired = false;
        DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);

        Thread t = new Thread(delegate() {
            while (DateTime.UtcNow < deadline) {
                if (Thread.VolatileRead(ref killGeneration) != mine) return;
                Thread.Sleep(250);
            }
            if (Thread.VolatileRead(ref killGeneration) != mine) return;
            try {
                Process p = Process.GetProcessById(pid);
                if (!p.HasExited) { KillFired = true; p.Kill(); }
            } catch (Exception) {
                // already gone, which is the outcome we wanted
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    public static void DisarmKill() { Interlocked.Increment(ref killGeneration); }

    // SetForegroundWindow is refused unless the calling thread already owns the
    // foreground, so borrow the target's input queue and nudge the foreground lock
    // with a stray Alt before asking.
    static bool Focus(IntPtr hwnd) {
        uint us = GetCurrentThreadId();
        uint them = GetWindowThreadProcessId(hwnd, IntPtr.Zero);

        for (int attempt = 0; attempt < 8; attempt++) {
            ShowWindow(hwnd, 9);                // SW_RESTORE
            AttachThreadInput(us, them, true);
            keybd_event(0x12, 0, 0, IntPtr.Zero);       // Alt down
            keybd_event(0x12, 0, 2, IntPtr.Zero);       // Alt up
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            SetActiveWindow(hwnd);
            AttachThreadInput(us, them, false);

            for (int i = 0; i < 10; i++) {
                if (GetForegroundWindow() == hwnd) return true;
                Thread.Sleep(50);
            }
        }
        return false;
    }

    // xemu's own screenshot directory. Set from the emulator's working directory.
    public static string ShotDir = "";

    // F12 makes xemu write the guest framebuffer out as a PNG, which is the frame the title
    // actually presented. Scraping the window instead is unreliable: a GPU-composited window
    // that is occluded or mid-resize grabs as a flat white rectangle, and that reads as a
    // presented frame, so a title that never drew anything passes as if it had.
    static Bitmap Grab(IntPtr hwnd) {
        LastGrabWasScrape = false;

        if (ShotDir.Length > 0 && Directory.Exists(ShotDir)) {
            DateTime since = DateTime.Now.AddSeconds(-1);

            // Without focus the keystroke lands in whatever window has it instead.
            if (Focus(hwnd)) {
                Thread.Sleep(150);
                keybd_event(0x7B, 0, 0, IntPtr.Zero);
                Thread.Sleep(60);
                keybd_event(0x7B, 0, 2, IntPtr.Zero);

                for (int i = 0; i < 30; i++) {
                    Thread.Sleep(100);
                    foreach (string f in Directory.GetFiles(ShotDir, "*.png")) {
                        if (File.GetLastWriteTime(f) < since) continue;
                        try {
                            Bitmap shot;
                            using (FileStream fs = File.OpenRead(f))
                                shot = new Bitmap(Image.FromStream(fs));
                            File.Delete(f);
                            return shot;
                        } catch (Exception) {
                            // still being written - come back on the next tick
                        }
                    }
                }
            }
        }

        LastGrabWasScrape = true;
        AnyGrabWasScrape = true;

        RECT r;
        if (!GetWindowRect(hwnd, out r)) return null;
        int ww = r.R - r.L, wh = r.B - r.T;
        if (ww <= 0 || wh <= 0) return null;

        Bitmap bmp = new Bitmap(ww, wh);
        using (Graphics g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            PrintWindow(hwnd, hdc, 2);      // PW_RENDERFULLCONTENT
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }

    // Returns "<md5 of pixels>:<lit samples out of 576>:<md5 of the sampled grid>".
    // Counting lit pixels tells a presented frame apart from the black frame that exists before
    // the title's first present. The bar is "not black" rather than "bright": plenty of samples
    // draw on a dark background, and a brighter bar counted those as unlit even with a model and
    // text on screen. The third field digests only the sampled grid, so a window scrape compares
    // equal whether or not xemu has focus.
    public static string Take(IntPtr hwnd, string path) {
        using (Bitmap bmp = Grab(hwnd)) {
            if (bmp == null) return "";
            int w = bmp.Width, h = bmp.Height;
            if (w <= 0 || h <= 0) return "";
            if (!string.IsNullOrEmpty(path)) bmp.Save(path, ImageFormat.Png);

            // skip the top eighth: on a window scrape that is the title bar, menu and overlay
            // toast, which are lit no matter what the guest drew
            int top = h / 8;
            int lit = 0;
            byte[] grid = new byte[24 * 24 * 3];
            for (int x = 0; x < 24; x++)
                for (int y = 0; y < 24; y++) {
                    Color c = bmp.GetPixel(x * (w - 1) / 23, top + y * (h - top - 1) / 23);
                    if (c.R + c.G + c.B > 24) lit++;
                    int o = (x * 24 + y) * 3;
                    grid[o] = c.R; grid[o + 1] = c.G; grid[o + 2] = c.B;
                }

            BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] buf = new byte[d.Stride * h];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            bmp.UnlockBits(d);
            using (MD5 md5 = MD5.Create()) {
                string full = BitConverter.ToString(md5.ComputeHash(buf)).Replace("-", "");
                string sig  = BitConverter.ToString(md5.ComputeHash(grid)).Replace("-", "");
                return full + ":" + lit + ":" + sig;
            }
        }
    }
}
'@

Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item $OutDir -ItemType Directory -Force | Out-Null

# Where xemu drops an F12 screenshot. Start from an empty directory so a grab can tell its own
# shot apart from one left behind by an earlier run.
$shotDir = Join-Path $XemuDir 'screenshots'
New-Item $shotDir -ItemType Directory -Force | Out-Null
Get-ChildItem $shotDir -Filter *.png -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
[XemuShot]::ShotDir = $shotDir

$isos = Get-ChildItem (Join-Path $Root 'XDKSamples') -Recurse -Filter *.iso |
    Where-Object { $_.FullName -match "\\out\\$Configuration\\XISO\\" } |
    Sort-Object Name
if ($Only) {
    # powershell -File hands "a,b,c" over as a single string, so split it back out
    $wanted = $Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $isos = $isos | Where-Object { $wanted -contains $_.BaseName }
}

"Running $($isos.Count) sample ISOs (sequential, early-exit)"
"artifacts: $OutDir"
''

# Lines the shared framework emits on the way up, and the failure detail that precedes a
# bailout. Everything here comes from XBApp/XBUtil/XBMesh/XBResource.
$reachedLoop = 'XBApp: Running the application\.\.\.'
$initFailed  = 'XBApp: Call to Initialize\(\) failed'
$reachedMain = 'RXDK\.start: main'
$detailRx    = 'Fatal System Error: 0x[0-9a-fA-F]+|Could not find file \[[^\]]+\]|ERROR: File not found|Invalid Xbox Packed Resource|Incorrect version number|Could not create|Unable to create|Call to CreateGamepads|ERROR: Invalid XBG file'
$emuLockRx   = 'Could not open|being used by another process|could not be opened'
# xemu aborting on its own assertion says nothing about the title: the serial log
# still ends on "Running the application", so without this it reads as a pass. xemu
# raises these two ways: the CRT's form, and GLib's from g_assert in the NV2A code.
$emuAbortRx  = 'Assertion failed: [^,]+, file [^,]+, line \d+|ERROR:[^\r\n]*: assertion failed[^\r\n]*' +
               # nv2a bails on a format it does not implement with a bare message and abort(), with
               # no assertion text to match. The window dies with it, so the title reads as one that
               # ran and drew nothing. Not to be confused with "Warning unimplemented feature",
               # which is survivable.
               '|nv2a: unimplemented [^\r\n]*|nv2a: unknown rdi [^\r\n]*'
# a bugcheck outranks everything else in the log: whatever the title last announced, it died
$fatalRx     = 'Fatal System Error: 0x[0-9a-fA-F]+'
# kernel refused the XBE, so the BIOS booted the dashboard and it complains about the disc
$loadFailed  = 'XeLoadTitleImge status2 = (?!00000000)[0-9A-Fa-f]{8}'

# xemu still holds these open while it runs, so plain ReadAllText is refused
function Read-Text([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { '' }
}

function Get-Status([string]$serial, [string]$stderr) {
    if ($serial -match $fatalRx)      { return 'CRASHED' }
    if ($serial -match $initFailed)   { return 'INIT FAILED' }
    if ($stderr -match $emuAbortRx)   { return 'EMULATOR ABORTED' }
    if ($serial -match $reachedLoop)  { return 'RUNS' }
    if ($serial -match $reachedMain)  { return 'STOPPED IN MAIN' }
    if ($serial -match $loadFailed)   { return 'WILL NOT LOAD' }
    if ($serial)                      { return 'NO BOOT' }
    if ($stderr -match $emuLockRx)    { return 'EMU LAUNCH FAILED' }
    return 'NO SERIAL OUTPUT'
}

function Stop-Xemu {
    Get-Process xemu -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process xemu -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 200
    }
    # process exit does not mean its handle on the locked HDD image is back
    Start-Sleep -Milliseconds 1500
}

# Every frame signature already seen, against the title that showed it first, so a title showing
# one of them can be recognised as still on the BIOS splash while the sweep is running - which is
# what earns a slow starter its second, longer attempt instead of a verdict on a frame it had not
# drawn yet. Keyed by title so a retry is not judged against its own earlier grab.
$script:SeenFrames = @{}

function Test-Seen([string]$sig, [string]$name) {
    return [bool]($sig -and $script:SeenFrames.ContainsKey($sig) -and $script:SeenFrames[$sig] -ne $name)
}

$results = @()
$i = 0

foreach ($iso in $isos) {
    $i++
    $name = $iso.BaseName

    $text = ''; $status = ''; $frozen = ''; $shot = ''
    $sw = $null; $used = 0; $wedged = $false

    foreach ($attempt in 1..2) {
        $used = $attempt
        $budget = $TimeoutSeconds * $attempt
        $log  = Join-Path $OutDir "$name.a$attempt.log"
        $err  = Join-Path $OutDir "$name.a$attempt.stderr.txt"
        $so   = Join-Path $OutDir "$name.a$attempt.stdout.txt"
        $png  = Join-Path $OutDir "$name.a$attempt.png"

        Stop-Xemu

        $proc = Start-Process -FilePath $xemu -WorkingDirectory $XemuDir -PassThru `
            -RedirectStandardError $err -RedirectStandardOutput $so `
            -ArgumentList @('-device', 'lpc47m157', '-serial', "file:$log", '-dvd_path', $iso.FullName)

        # Hard ceiling on the whole attempt, capture included, enforced from outside this
        # thread: whatever the harness is blocked on, the emulator dies and the sweep moves on.
        # Generous, because the honest worst case is the budget plus six focus-and-grab rounds.
        [XemuShot]::ArmKill($proc.Id, $budget + 120)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $verdictAt = $null
        $text = ''

        while ($sw.Elapsed.TotalSeconds -lt $budget) {
            Start-Sleep -Milliseconds 500
            $text = Read-Text $log
            if (-not $verdictAt -and ($text -match $initFailed -or $text -match $reachedLoop)) {
                $verdictAt = $sw.Elapsed.TotalSeconds
            }
            # once a verdict lands, linger briefly to catch anything that follows
            if ($verdictAt -and ($sw.Elapsed.TotalSeconds - $verdictAt) -ge $GraceSeconds) { break }
            if ($proc.HasExited -and $text) { break }
        }

        $errText = Read-Text $err
        $status = Get-Status $text $errText

        # Reaching the render loop happens a beat before the first present, so a title caught
        # right on its verdict grabs as a black window. Give a running title a few chances to
        # put something on screen; anything already failed gets one shot and no waiting.
        $frozen = ''; $shot = ''; $presented = ''; $frameSig = ''; $lit = 0
        # A title with no framework marker may still be presenting, so it gets the same
        # patience as a known-good one; anything that already failed gets one shot.
        $tries = if ($status -in 'RUNS', 'STOPPED IN MAIN') { 6 } else { 1 }
        [XemuShot]::ResetScrape()
        $proc.Refresh()
        if (-not $proc.HasExited -and $proc.MainWindowHandle -ne 0 -and
            -not [XemuShot]::WindowHung($proc.MainWindowHandle)) {
            $first = ''
            foreach ($t in 1..$tries) {
                $first = [XemuShot]::Take($proc.MainWindowHandle, $png)
                if (-not $first) { break }
                # keep waiting while the screen is unlit or still showing a frame an earlier title
                # left on it: the render loop is reached a beat before the first present, so a
                # title caught on its verdict grabs black or grabs the splash
                $sig = ($first -split ':')[2]
                if ([int]($first -split ':')[1] -ge 20 -and -not (Test-Seen $sig $name)) { break }
                Start-Sleep -Milliseconds 1000
            }
            if ($first) {
                $frameSig = ($first -split ':')[2]
                $lit = [int]($first -split ':')[1]
                $presented = ($lit -ge 20) -and -not (Test-Seen $frameSig $name)
                if (-not $script:SeenFrames.ContainsKey($frameSig)) { $script:SeenFrames[$frameSig] = $name }
            }
            # a second frame a beat later: an identical pair means nothing is animating, which
            # is how a title wedged on the BIOS logo or hung in its loop looks from outside
            Start-Sleep -Milliseconds 1200
            $second = [XemuShot]::Take($proc.MainWindowHandle, '')
            if ($first) { $shot = Split-Path $png -Leaf; $frozen = ($first -eq $second) }
        }

        if ([XemuShot]::KillFired) { $wedged = $true }
        [XemuShot]::DisarmKill()
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
        $text = Read-Text $log
        $errText = Read-Text $err
        # the title kept running while we were taking pictures, so judge it on the final log
        $status = Get-Status $text $errText

        # The D3D tutorials and the Xbox Live samples never link CXBApplication, so they never
        # print the line that proves the render loop was reached and they read as a hang. If such
        # a title got to main and put something on screen, take it as running - but say so
        # separately, because without the framework's own word for it this is the weaker verdict.
        # The cross-title frame comparison after the sweep takes this back if the screen turns
        # out to have been the BIOS splash all along.
        if ($status -eq 'STOPPED IN MAIN' -and $presented -eq $true) { $status = 'RUNS (NO FRAMEWORK)' }

        if ($status -in 'RUNS', 'RUNS (NO FRAMEWORK)', 'INIT FAILED', 'CRASHED', 'WILL NOT LOAD', 'EMULATOR ABORTED') { break }
    }

    $detail = ''
    $hits = [regex]::Matches($text, $detailRx)
    if ($hits.Count) { $detail = (($hits | ForEach-Object { $_.Value }) | Select-Object -Unique) -join '; ' }
    if ($status -eq 'EMULATOR ABORTED') {
        $m = [regex]::Match($errText, $emuAbortRx)
        if ($m.Success) { $detail = $m.Value }
    }
    # A title still showing the BIOS splash never got a frame of its own to the screen, which
    # matters most for one the log calls RUNS: it reached its render loop and drew nothing.
    $scraped = [XemuShot]::AnyGrabWasScrape
    if (-not $detail -and $presented -eq $false -and $scraped) {
        $detail = 'no picture, but the grab was a window scrape - pixels not trustworthy'
    }
    if (-not $detail -and $presented -eq $false) { $detail = 'never presented (still on BIOS splash)' }
    if (-not $detail -and $status -like 'RUNS*' -and $frozen -eq $true) { $detail = 'frame did not change' }
    # Worth saying out loud: the emulator stopped responding and had to be killed from outside,
    # so this sample's pixels and timing are not evidence of anything.
    if ($wedged) { $detail = (@('emulator wedged - watchdog killed it', $detail) | Where-Object { $_ }) -join '; ' }

    $results += [pscustomobject]@{
        Sample    = $name
        Status    = $status
        Seconds   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Attempts  = $used
        Presented = $presented
        Frozen    = $frozen
        Shot      = $shot
        Frame     = $frameSig
        Lit       = $lit
        Detail    = $detail
    }

    "{0,3}/{1}  {2,-26} {3,-18} {4,5}s  {5}" -f $i, $isos.Count, $name, $status, $results[-1].Seconds, $detail
}

Stop-Xemu

# A frame that several titles produced pixel for pixel is not any of their own work: it is what the
# BIOS left on screen, which a title wedged before its first present never replaces. Comparing
# titles against each other is the only reliable way to spot that. Grabbing the splash before the
# XBE takes over does not work - the BIOS hands over inside the first poll, faster than a
# screenshot can be taken - and from one title alone a stale splash is indistinguishable from a
# static scene the title drew on purpose.
#
# Two titles sharing a frame is not enough to convict: the tree carries the same sample under two
# names in places, and those legitimately draw the same thing. Three independent titles do not.
$groups = $results | Where-Object { $_.Frame } | Group-Object Frame | Where-Object { $_.Count -gt 1 }
$shared = @($groups | Where-Object { $_.Count -ge 3 })

# what one boot could guess about the picture is superseded by what the comparison establishes
function Add-Note([object]$r, [string]$note) {
    $guesses = @('frame did not change', 'never presented (still on BIOS splash)')
    $keep = if ($r.Detail -and $guesses -notcontains $r.Detail) { $r.Detail } else { '' }
    $r.Detail = if ($keep) { "$keep; $note" } else { $note }
}

foreach ($group in $shared) {
    foreach ($r in $group.Group) {
        $r.Presented = $false
        # without a frame of its own, a title with no framework trace has nothing left to vouch for it
        if ($r.Status -eq 'RUNS (NO FRAMEWORK)') { $r.Status = 'STOPPED IN MAIN' }
        Add-Note $r "never presented: same frame as $($group.Count - 1) other titles, so this is the BIOS splash"
    }
}

# A pair keeps its pixels, since the likeliest explanation is one sample built twice - but say so,
# because the other explanation is both being stuck on the same splash.
foreach ($group in ($groups | Where-Object { $_.Count -eq 2 })) {
    foreach ($r in $group.Group) {
        if ($r.Lit -ge 20 -and $r.Presented -eq $false) {
            $r.Presented = $true
            if ($r.Status -eq 'STOPPED IN MAIN') { $r.Status = 'RUNS (NO FRAMEWORK)' }
        }
        $other = ($group.Group | Where-Object { $_.Sample -ne $r.Sample } | ForEach-Object { $_.Sample }) -join ', '
        Add-Note $r "same frame as $other - two builds of one sample, or both stuck on the same screen"
    }
}

$csv = Join-Path $OutDir 'results.csv'
$results | Export-Csv $csv -NoTypeInformation

''
'==== summary ===='
$results | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
    "{0,-18} {1}" -f $_.Name, $_.Count
}
$blank = @($results | Where-Object { $_.Status -like 'RUNS*' -and $_.Presented -eq $false })
if ($blank) { "{0,-18} {1}   (reached the loop but never presented a frame)" -f 'NO PICTURE', $blank.Count }
$stuck = @($results | Where-Object { $_.Status -like 'RUNS*' -and $_.Presented -eq $true -and $_.Frozen -eq $true })
if ($stuck) { "{0,-18} {1}   (presented once, then the frame never changed)" -f 'FROZEN', $stuck.Count }
if ($shared) {
    ''
    'Nothing of their own ever reached the screen (frame shared with another title):'
    $shared | ForEach-Object { $_.Group } | Sort-Object Sample | ForEach-Object {
        "  {0,-26} {1}" -f $_.Sample, $_.Status
    }
}
''
"artifacts: $OutDir"
"csv      : $csv"
