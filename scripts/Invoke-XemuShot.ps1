# Boots an ISO in xemu, captures the serial log, screenshots the window, and exits.
# Used to check a sample end to end without a devkit.
param(
    [Parameter(Mandatory = $true)][string] $Iso,
    [Parameter(Mandatory = $true)][string] $Log,
    [Parameter(Mandatory = $true)][string] $Shot,
    [int] $Seconds = 20,
    [string] $XemuDir = "D:\Git\xemu-devkit"
)

$ErrorActionPreference = "Stop"
Remove-Item $Log, $Shot -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath (Join-Path $XemuDir "xemu.exe") -WorkingDirectory $XemuDir -PassThru `
    -ArgumentList @("-device", "lpc47m157", "-serial", "file:$Log", "-dvd_path", $Iso)

Start-Sleep -Seconds $Seconds

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@

$proc.Refresh()
$hwnd = $proc.MainWindowHandle
if ($hwnd -ne [IntPtr]::Zero) {
    # CopyFromScreen reads the desktop, so the emulator has to actually be on top.
    [void][Win32]::ShowWindow($hwnd, 9) # SW_RESTORE
    [void][Win32]::BringWindowToTop($hwnd)
    [void][Win32]::SetForegroundWindow($hwnd)
    Start-Sleep -Seconds 2

    $rect = New-Object Win32+RECT
    [void][Win32]::GetClientRect($hwnd, [ref]$rect)
    $origin = New-Object Win32+POINT
    [void][Win32]::ClientToScreen($hwnd, [ref]$origin)
    $w = $rect.R - $rect.L
    $h = $rect.B - $rect.T
    if ($w -gt 0 -and $h -gt 0) {
        $bmp = New-Object Drawing.Bitmap $w, $h
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bmp.Size)
        $bmp.Save($Shot, [Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    }
}

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
"log:  $Log"
"shot: $Shot"
