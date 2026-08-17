<#
.SYNOPSIS
Breakpoints a guest address in xemu, then single-steps and logs EIP.

.DESCRIPTION
Answers "where does the CPU actually go from here" when a title stops making
progress. Uses hardware breakpoints (Z1) rather than software ones (Z0): Z0
pokes 0xCC into guest memory, which the XBE loader would overwrite when the
title is loaded after this script connects.

Intended to be used against 'xemu -s -S', so breakpoints can be planted before
the guest executes anything.
#>
[CmdletBinding()]
param(
    [string[]] $Breakpoints = @('1b3309'),
    [int]      $Steps = 60,
    [int]      $WaitSeconds = 90,
    [string]   $XemuHost = '127.0.0.1',
    [int]      $Port = 1234,
    [switch]   $Resume
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
            # A bare '+'/'-' is only an ack for what we sent; the real reply is a
            # '$...#xx' packet that may arrive much later (e.g. when a breakpoint
            # finally hits), so keep reading until a full packet is present.
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

function Get-Eip {
    param([System.Net.Sockets.NetworkStream] $Stream)
    Send-Packet -Stream $Stream -Data 'g'
    $hex = Read-Packet -Stream $Stream
    if ($hex.Length -lt 72) { return $null }
    $b = $hex.Substring(64, 8)   # register index 8 = eip
    return [Convert]::ToUInt32($b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2), 16)
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($XemuHost, $Port)
$stream = $client.GetStream()
$stream.WriteTimeout = 4000

try {
    foreach ($bp in $Breakpoints) {
        $r = $null
        Send-Packet -Stream $stream -Data ("Z1,{0},1" -f $bp)
        $r = Read-Packet -Stream $stream
        Write-Host ("breakpoint 0x{0} -> '{1}'" -f $bp, $r)
    }

    Write-Host ''
    Write-Host "continuing, waiting up to ${WaitSeconds}s for a hit..."
    Send-Packet -Stream $stream -Data 'c'
    $stop = Read-Packet -Stream $stream -TimeoutMs ($WaitSeconds * 1000)

    if ([string]::IsNullOrWhiteSpace($stop)) {
        Write-Host 'NO HIT: breakpoint was never reached within the window.'
        return
    }

    Write-Host "HIT: stop reply '$stop'"
    $eip = Get-Eip -Stream $stream
    Write-Host ("stopped at eip = 0x{0:X8}" -f $eip)

    # Full register block plus the frame slots, to tell "return address was
    # overwritten" apart from "esp drifted so the epilogue popped the wrong slots".
    Send-Packet -Stream $stream -Data 'g'
    $regHex = Read-Packet -Stream $stream
    $rn = @('eax','ecx','edx','ebx','esp','ebp','esi','edi','eip','eflags')
    $rv = @{}
    for ($i = 0; $i -lt $rn.Count; $i++) {
        $b = $regHex.Substring($i * 8, 8)
        $rv[$rn[$i]] = [Convert]::ToUInt32($b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2), 16)
    }
    Write-Host ''
    foreach ($n in $rn) { Write-Host ("  {0,-7}= 0x{1:X8}" -f $n, $rv[$n]) }

    foreach ($probe in @(@{n='[ebp+4] (saved ret)'; a=$rv['ebp'] + 4},
                         @{n='[ebp+0] (saved ebp)'; a=$rv['ebp']},
                         @{n='[esp+0]'; a=$rv['esp']})) {
        Send-Packet -Stream $stream -Data ("m{0:x},4" -f $probe.a)
        $h = Read-Packet -Stream $stream
        if ($h -match '^[0-9a-fA-F]{8}$') {
            $v = [Convert]::ToUInt32($h.Substring(6,2) + $h.Substring(4,2) + $h.Substring(2,2) + $h.Substring(0,2), 16)
            Write-Host ("  {0,-20} @ 0x{1:X8} = 0x{2:X8}" -f $probe.n, $probe.a, $v)
        } else {
            Write-Host ("  {0,-20} @ 0x{1:X8} = unreadable ({2})" -f $probe.n, $probe.a, $h)
        }
    }

    Write-Host ''
    Write-Host "===== single-stepping $Steps instructions ====="
    for ($i = 1; $i -le $Steps; $i++) {
        Send-Packet -Stream $stream -Data 's'
        $s = Read-Packet -Stream $stream -TimeoutMs 8000
        if ([string]::IsNullOrWhiteSpace($s)) {
            Write-Host "  step $i : no reply (guest did not stop - likely blocked)"
            break
        }
        $eip = Get-Eip -Stream $stream
        Write-Host ("  step {0,-3} eip = 0x{1:X8}" -f $i, $eip)
    }

    if ($Resume) {
        foreach ($bp in $Breakpoints) {
            Send-Packet -Stream $stream -Data ("z1,{0},1" -f $bp)
            [void] (Read-Packet -Stream $stream)
        }
        Send-Packet -Stream $stream -Data 'c'
        Write-Host ''
        Write-Host 'breakpoints cleared, guest resumed'
    }
}
finally {
    $stream.Dispose()
    $client.Dispose()
}
