<#
.SYNOPSIS
Reads guest memory through xemu's GDB stub and optionally disassembles it.

.DESCRIPTION
Companion to Get-XemuCpuState.ps1. Halting the guest and reading raw bytes is
only half the story - the bytes have to be decoded to mean anything, so this
pipes them through llvm-mc when -Disassemble is given.
#>
[CmdletBinding()]
param(
    # String, because PowerShell parses a literal like 0x8001E830 as a signed int32
    # and refuses to widen it to uint32.
    [Parameter(Mandatory)] [string] $Address,
    [int]    $Length = 64,
    [string] $XemuHost = '127.0.0.1',
    [int]    $Port = 1234,
    [switch] $Disassemble,
    [switch] $Words,
    [switch] $Resume
)

$ErrorActionPreference = 'Stop'

$addr = if ($Address -match '^0[xX]') {
    [Convert]::ToUInt32($Address.Substring(2), 16)
} else {
    [Convert]::ToUInt32($Address)
}

function Send-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream, [string] $Data)
    $sum = 0
    foreach ($ch in [char[]] $Data) { $sum = ($sum + [int] $ch) % 256 }
    $pkt = '$' + $Data + '#' + $sum.ToString('x2')
    $bytes = [Text.Encoding]::ASCII.GetBytes($pkt)
    $Stream.Write($bytes, 0, $bytes.Length); $Stream.Flush()
}

function Read-Packet {
    param([System.Net.Sockets.NetworkStream] $Stream)
    $sb = New-Object Text.StringBuilder
    $buf = New-Object byte[] 16384
    while ($true) {
        try { $n = $Stream.Read($buf, 0, $buf.Length) } catch { break }
        if ($n -le 0) { break }
        [void] $sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
        if ($sb.ToString() -match '#[0-9a-fA-F]{2}') { break }
    }
    $raw = $sb.ToString()
    $ack = [Text.Encoding]::ASCII.GetBytes('+')
    try { $Stream.Write($ack, 0, 1); $Stream.Flush() } catch { }
    if ($raw -match '\$([^#]*)#') { return $Matches[1] }
    return $raw
}

$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($XemuHost, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 4000
$stream.WriteTimeout = 4000

try {
    $stream.WriteByte(3); $stream.Flush()
    [void] (Read-Packet -Stream $stream)

    Send-Packet -Stream $stream -Data ("m{0:x},{1:x}" -f $addr, $Length)
    $hex = Read-Packet -Stream $stream

    if ($hex -match '^E' -or [string]::IsNullOrWhiteSpace($hex)) {
        throw "memory read failed at 0x$('{0:X8}' -f $addr): '$hex'"
    }

    Write-Host "0x$('{0:X8}' -f $addr) ($Length bytes):"
    Write-Host $hex

    if ($Words) {
        Write-Host ''
        $n = [Math]::Floor($hex.Length / 8)
        for ($i = 0; $i -lt $n; $i++) {
            $b = $hex.Substring($i * 8, 8)
            $v = [Convert]::ToUInt32($b.Substring(6,2) + $b.Substring(4,2) + $b.Substring(2,2) + $b.Substring(0,2), 16)
            Write-Host ("  +{0,-4} 0x{1:X8}" -f ($i * 4), $v)
        }
    }

    if ($Disassemble) {
        $pairs = @()
        for ($i = 0; $i -lt $hex.Length; $i += 2) { $pairs += '0x' + $hex.Substring($i, 2) }
        $tmp = Join-Path $env:TEMP 'xemu-disasm.txt'
        Set-Content -Path $tmp -Value ($pairs -join ' ') -Encoding ASCII
        Write-Host ''
        Write-Host "--- disassembly (i386, base 0x$('{0:X8}' -f $addr)) ---"
        & "C:\Program Files\LLVM\bin\llvm-mc.exe" --disassemble --triple=i386 $tmp 2>&1 |
            Where-Object { $_ -notmatch '^\s*\.text\s*$' }
    }

    if ($Resume) { Send-Packet -Stream $stream -Data 'c'; Write-Host ''; Write-Host 'guest resumed' }
}
finally {
    $stream.Dispose()
    $client.Dispose()
}
