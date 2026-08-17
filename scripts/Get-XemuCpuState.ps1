<#
.SYNOPSIS
Halts a running xemu via its GDB stub and reports the guest CPU state.

.DESCRIPTION
xemu is QEMU-based, so '-s' exposes a GDB remote serial protocol stub on tcp:1234.
Rather than depend on a matching i386 gdb binary being installed, this speaks the
protocol directly: interrupt the guest, read the register block, disassemble-adjacent
memory, and walk the stack. Enough to answer "where is the CPU actually stuck".

The guest is left halted unless -Continue is passed, so several reads can be taken
of the same stopped state.
#>
[CmdletBinding()]
param(
    [string] $XemuHost = '127.0.0.1',
    [int]    $Port = 1234,
    [int]    $StackWords = 24,
    [int]    $CodeBytes = 32,
    [switch] $Resume
)

$ErrorActionPreference = 'Stop'

function Send-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream, [string] $Data)
    $sum = 0
    foreach ($ch in [char[]] $Data) { $sum = ($sum + [int] $ch) % 256 }
    $pkt = '$' + $Data + '#' + $sum.ToString('x2')
    $bytes = [Text.Encoding]::ASCII.GetBytes($pkt)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream)
    $sb = New-Object Text.StringBuilder
    $buf = New-Object byte[] 8192
    # The stub answers a single packet per request; stop as soon as the trailing
    # checksum arrives so we never block on the next read.
    while ($true) {
        try { $n = $Stream.Read($buf, 0, $buf.Length) } catch { break }
        if ($n -le 0) { break }
        [void] $sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
        if ($sb.ToString() -match '#[0-9a-fA-F]{2}') { break }
    }
    $raw = $sb.ToString()
    # Ack, otherwise the stub retransmits and later replies arrive out of step.
    $ack = [Text.Encoding]::ASCII.GetBytes('+')
    try { $Stream.Write($ack, 0, 1); $Stream.Flush() } catch { }
    if ($raw -match '\$([^#]*)#') { return $Matches[1] }
    return $raw
}

function Invoke-Rsp {
    param([System.Net.Sockets.NetworkStream] $Stream, [string] $Command)
    Send-Packet -Stream $Stream -Data $Command
    return Read-Packet -Stream $Stream
}

# little-endian hex pairs -> UInt32
function ConvertFrom-LeHex {
    param([string] $Hex, [int] $Index)
    $o = $Index * 8
    if ($Hex.Length -lt $o + 8) { return $null }
    $b = $Hex.Substring($o, 8)
    return [Convert]::ToUInt32($b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2), 16)
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($XemuHost, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 4000
$stream.WriteTimeout = 4000

try {
    # Raw 0x03 (not a packet) is the protocol's interrupt request.
    $stream.WriteByte(3)
    $stream.Flush()
    $stop = Read-Packet -Stream $stream
    Write-Host "stop reply : $stop"

    $regs = Invoke-Rsp -Stream $stream -Command 'g'
    if ($regs -match '^E' -or [string]::IsNullOrWhiteSpace($regs)) {
        throw "register read failed: '$regs'"
    }

    # qemu-i386 'g' block starts: eax ecx edx ebx esp ebp esi edi eip eflags cs ss ds es fs gs
    $names = @('eax','ecx','edx','ebx','esp','ebp','esi','edi','eip','eflags')
    $vals = @{}
    for ($i = 0; $i -lt $names.Count; $i++) {
        $vals[$names[$i]] = ConvertFrom-LeHex -Hex $regs -Index $i
    }

    Write-Host ''
    Write-Host '===== guest CPU ====='
    foreach ($n in $names) {
        Write-Host ("{0,-7}= {1}" -f $n, ('0x{0:X8}' -f $vals[$n]))
    }

    $eip = $vals['eip']
    $esp = $vals['esp']
    $ebp = $vals['ebp']

    Write-Host ''
    Write-Host "===== code at eip (0x$('{0:X8}' -f $eip)) ====="
    $back = 8
    $codeAddr = $eip - $back
    $code = Invoke-Rsp -Stream $stream -Command ("m{0:x},{1:x}" -f $codeAddr, $CodeBytes)
    if ($code -match '^E') {
        Write-Host "  unreadable ($code)"
    } else {
        Write-Host "  addr 0x$('{0:X8}' -f $codeAddr): $code"
        Write-Host "  (eip is $back bytes into the above)"
    }

    Write-Host ''
    Write-Host "===== stack at esp (0x$('{0:X8}' -f $esp)) ====="
    $stk = Invoke-Rsp -Stream $stream -Command ("m{0:x},{1:x}" -f $esp, ($StackWords * 4))
    if ($stk -match '^E') {
        Write-Host "  unreadable ($stk)"
    } else {
        for ($i = 0; $i -lt $StackWords; $i++) {
            $w = ConvertFrom-LeHex -Hex $stk -Index $i
            if ($null -eq $w) { break }
            Write-Host ("  [esp+{0,-3}] 0x{1:X8}" -f ($i * 4), $w)
        }
    }

    Write-Host ''
    Write-Host "===== frame chain from ebp (0x$('{0:X8}' -f $ebp)) ====="
    $cur = $ebp
    for ($depth = 0; $depth -lt 12; $depth++) {
        if ($cur -eq 0 -or $cur -lt 0x1000) { break }
        $fr = Invoke-Rsp -Stream $stream -Command ("m{0:x},8" -f $cur)
        if ($fr -match '^E') { Write-Host "  frame $depth at 0x$('{0:X8}' -f $cur): unreadable"; break }
        $next = ConvertFrom-LeHex -Hex $fr -Index 0
        $ret = ConvertFrom-LeHex -Hex $fr -Index 1
        Write-Host ("  frame {0,-2} ebp=0x{1:X8}  ret=0x{2:X8}" -f $depth, $cur, $ret)
        if ($next -eq $cur) { break }
        $cur = $next
    }

    if ($Resume) {
        Send-Packet -Stream $stream -Data 'c'
        Write-Host ''
        Write-Host 'guest resumed'
    } else {
        Write-Host ''
        Write-Host 'guest left HALTED (rerun with -Resume, or just kill xemu)'
    }
}
finally {
    $stream.Dispose()
    $client.Dispose()
}
