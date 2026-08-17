<#
.SYNOPSIS
Tracks the guest stack pointer across a series of guest addresses.

.DESCRIPTION
Diagnoses a stack-pointer leak: at -O0 clang gives a function one fixed frame, so
esp must read identically at every point in that function's body. Wherever esp
steps down, the call just before it failed to pop what the caller assumed it would
(a __stdcall/__cdecl mismatch).

Only 4 hardware breakpoints exist (DR0-DR3), so this plants one hardware
breakpoint to catch the title once its code is resident, then switches to
software breakpoints (which need the XBE already loaded) for the rest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]   $Anchor,
    [Parameter(Mandatory)] [string[]] $Addresses,
    [int]    $MaxStops = 40,
    [int]    $WaitSeconds = 90,
    [string] $XemuHost = '127.0.0.1',
    [int]    $Port = 1234
)

$ErrorActionPreference = 'Stop'

function Send-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream, [string] $Data)
    $sum = 0
    foreach ($ch in [char[]] $Data) { $sum = ($sum + [int] $ch) % 256 }
    $pkt = '$' + $Data + '#' + $sum.ToString('x2')
    $bytes = [Text.Encoding]::ASCII.GetBytes($pkt)
    $Stream.Write($bytes, 0, $bytes.Length); $Stream.Flush()
}

function Read-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream, [int] $TimeoutMs = 4000)
    $old = $Stream.ReadTimeout
    $Stream.ReadTimeout = $TimeoutMs
    $sb = New-Object Text.StringBuilder
    $buf = New-Object byte[] 16384
    try {
        while ($true) {
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void] $sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            if ($sb.ToString() -match '\$[^#]*#[0-9a-fA-F]{2}') { break }
        }
    } catch { }
    finally { $Stream.ReadTimeout = $old }
    $raw = $sb.ToString()
    $ack = [Text.Encoding]::ASCII.GetBytes('+')
    try { $Stream.Write($ack, 0, 1); $Stream.Flush() } catch { }
    if ($raw -match '\$([^#]*)#') { return $Matches[1] }
    return $raw
}

function Get-Regs {
    param([System.Net.Sockets.NetworkStream] $Stream)
    Send-Packet -Stream $Stream -Data 'g'
    $hex = Read-Packet -Stream $Stream
    if ($hex.Length -lt 72) { return $null }
    $get = {
        param($i)
        $b = $hex.Substring($i * 8, 8)
        [Convert]::ToUInt32($b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2), 16)
    }
    return @{ esp = (& $get 4); ebp = (& $get 5); eip = (& $get 8) }
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($XemuHost, $Port)
$stream = $client.GetStream()
$stream.WriteTimeout = 4000

try {
    Send-Packet -Stream $stream -Data ("Z1,{0},1" -f $Anchor)
    Write-Host ("anchor hw breakpoint 0x{0} -> '{1}'" -f $Anchor, (Read-Packet -Stream $stream))

    Write-Host "waiting for anchor..."
    Send-Packet -Stream $stream -Data 'c'
    $stop = Read-Packet -Stream $stream -TimeoutMs ($WaitSeconds * 1000)
    if ([string]::IsNullOrWhiteSpace($stop)) { Write-Host 'anchor never hit'; return }

    $r = Get-Regs -Stream $stream
    Write-Host ("anchor hit: eip=0x{0:X8} esp=0x{1:X8} ebp=0x{2:X8}" -f $r.eip, $r.esp, $r.ebp)
    $baseline = $r.esp

    # Code is resident now, so software breakpoints will stick.
    Send-Packet -Stream $stream -Data ("z1,{0},1" -f $Anchor)
    [void] (Read-Packet -Stream $stream)
    foreach ($a in $Addresses) {
        Send-Packet -Stream $stream -Data ("Z0,{0},1" -f $a)
        $res = Read-Packet -Stream $stream
        if ($res -ne 'OK') { Write-Host ("  warn: Z0 at 0x{0} -> '{1}'" -f $a, $res) }
    }
    Write-Host ("planted {0} software breakpoints" -f $Addresses.Count)

    Write-Host ''
    Write-Host '===== esp at each call return ====='
    Write-Host ("  baseline esp = 0x{0:X8}" -f $baseline)
    $prev = $baseline
    for ($i = 1; $i -le $MaxStops; $i++) {
        if ($i -gt 1) {
            # Resuming while still parked on a breakpoint address re-triggers it
            # immediately, so step off it first.
            Send-Packet -Stream $stream -Data 's'
            [void] (Read-Packet -Stream $stream -TimeoutMs 8000)
        }
        Send-Packet -Stream $stream -Data 'c'
        $s = Read-Packet -Stream $stream -TimeoutMs 20000
        if ([string]::IsNullOrWhiteSpace($s)) { Write-Host '  (no further stops)'; break }
        $r = Get-Regs -Stream $stream
        if ($null -eq $r) { Write-Host '  (register read failed)'; break }
        $delta = [int64] $r.esp - [int64] $prev
        $flag = if ($delta -ne 0) { "   <== LEAKED $([Math]::Abs($delta)) bytes" } else { '' }
        Write-Host ("  eip=0x{0:X8}  esp=0x{1:X8}  delta={2,4}{3}" -f $r.eip, $r.esp, $delta, $flag)
        $prev = $r.esp
    }
}
finally {
    $stream.Dispose()
    $client.Dispose()
}
