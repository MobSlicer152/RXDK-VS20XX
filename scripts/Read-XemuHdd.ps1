<#
.SYNOPSIS
Reads the FATX partitions of the xemu Xbox HDD image: list a directory, or extract a file.

.DESCRIPTION
Read-only. Exists because some sample failures are decided by what is (or is not) on the
console's hard disk rather than by anything in the build - the debug samples import XBDM.DLL,
which the BIOS only loads when it finds both E:\xbdm.dll and a config enabling it.

Paths are given drive-qualified, e.g. 'E:\DEVKIT\xbdm.ini'. Only C: and E: are mapped; the
three cache partitions hold nothing of interest here.

.EXAMPLE
Read-XemuHdd.ps1 -List 'E:\'
.EXAMPLE
Read-XemuHdd.ps1 -Cat 'E:\DEVKIT\xbdm.ini'
.EXAMPLE
Read-XemuHdd.ps1 -Extract 'E:\xbdm.dll' -To .\xbdm.dll
#>
[CmdletBinding()]
param(
    [string] $Image = 'D:\Git\xemu-devkit\roms\Original Xbox HDD Image.bin',
    [string] $List,
    [string] $Cat,
    [string] $Extract,
    [string] $To
)

$ErrorActionPreference = 'Stop'

# fixed offsets of the standard retail partition layout
$PartitionMap = @{
    'C' = @(0x8CA80000L, 0x1F400000L)
    'E' = @(0xABE80000L, 0x01312D6000L)
}

class Fatx {
    [IO.FileStream] $Stream
    [int]  $ClusterBytes
    [int]  $EntryBytes
    [long] $DataStart
    [byte[]] $Fat

    Fatx([IO.FileStream]$stream, [long]$offset, [long]$length) {
        $this.Stream = $stream
        $stream.Position = $offset
        $header = [byte[]]::new(4096)
        $this.ReadFully($header, 4096)
        if ([Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'FATX') { throw "no FATX magic at 0x$('{0:X}' -f $offset)" }

        $this.ClusterBytes = [int]([BitConverter]::ToUInt32($header, 8) * 512)
        $clusters   = [long]($length / $this.ClusterBytes)
        $this.EntryBytes = $(if ($clusters -ge 0xFFF0) { 4 } else { 2 })
        $fatBytes   = [long][Math]::Ceiling(($clusters * $this.EntryBytes) / 4096.0) * 4096
        $this.DataStart = $offset + 4096 + $fatBytes

        $stream.Position = $offset + 4096
        $this.Fat = [byte[]]::new($fatBytes)
        $this.ReadFully($this.Fat, $fatBytes)
    }

    # a single Read is not obliged to return everything asked for
    [void] ReadFully([byte[]]$buffer, [long]$count) {
        $got = 0
        while ($got -lt $count) {
            $n = $this.Stream.Read($buffer, $got, [int][Math]::Min(1MB, $count - $got))
            if ($n -le 0) { break }
            $got += $n
        }
    }

    [int] NextCluster([int]$c) {
        if ($this.EntryBytes -eq 2) {
            $v = [BitConverter]::ToUInt16($this.Fat, $c * 2)
            if ($v -ge 0xFFF8) { return -1 }
            return [int]$v
        }
        $v = [BitConverter]::ToUInt32($this.Fat, $c * 4)
        # 0xFFFFFFF8 written bare is Int32 -8 in PowerShell, so the bound must be 64-bit
        if ($v -ge 0xFFFFFFF8L -or $v -eq 0) { return -1 }
        return [int]$v
    }

    [byte[]] ReadCluster([int]$c) {
        $this.Stream.Position = $this.DataStart + ([long]($c - 1) * $this.ClusterBytes)
        $buf = [byte[]]::new($this.ClusterBytes)
        $this.ReadFully($buf, $this.ClusterBytes)
        return $buf
    }

    [object[]] ReadDir([int]$cluster) {
        $items = @()
        $c = $cluster
        $guard = 0
        while ($c -gt 0 -and $guard -lt 4096) {
            $guard++
            $buf = $this.ReadCluster($c)
            $end = $false
            for ($i = 0; $i -lt $this.ClusterBytes; $i += 64) {
                $len = $buf[$i]
                if ($len -eq 0x00 -or $len -eq 0xFF) { $end = $true; break }
                if ($len -eq 0xE5 -or $len -gt 42) { continue }
                $items += [pscustomobject]@{
                    Name  = [Text.Encoding]::ASCII.GetString($buf, $i + 2, $len)
                    IsDir = [bool]($buf[$i + 1] -band 0x10)
                    First = [int][BitConverter]::ToUInt32($buf, $i + 0x2C)
                    Size  = [long][BitConverter]::ToUInt32($buf, $i + 0x30)
                }
            }
            if ($end) { break }
            $c = $this.NextCluster($c)
        }
        return $items
    }

    [object] Find([string[]]$parts) {
        $cluster = 1
        $entry = $null
        foreach ($part in $parts) {
            $entry = $this.ReadDir($cluster) | Where-Object { $_.Name -ieq $part } | Select-Object -First 1
            if (-not $entry) { return $null }
            $cluster = $entry.First
        }
        return $entry
    }

    [byte[]] ReadFile([int]$first, [long]$size) {
        $ms = [IO.MemoryStream]::new()
        $c = $first
        $left = $size
        while ($left -gt 0 -and $c -gt 0) {
            $buf = $this.ReadCluster($c)
            $take = [int][Math]::Min([long]$this.ClusterBytes, $left)
            $ms.Write($buf, 0, $take)
            $left -= $take
            if ($left -le 0) { break }
            $c = $this.NextCluster($c)
        }
        return $ms.ToArray()
    }
}

function Split-XboxPath([string]$path) {
    $drive = $path.Substring(0, 1).ToUpper()
    if (-not $PartitionMap.ContainsKey($drive)) { throw "unmapped drive '$drive' (only C: and E:)" }
    $rest = $path.Substring(2).Trim('\')
    $parts = if ($rest) { $rest -split '\\' } else { @() }
    return @{ Drive = $drive; Parts = $parts }
}

$target = if ($List) { $List } elseif ($Cat) { $Cat } elseif ($Extract) { $Extract } else { $null }
if (-not $target) { throw 'pass one of -List, -Cat or -Extract' }

$parsed = Split-XboxPath $target
$where  = $PartitionMap[$parsed.Drive]

$stream = [IO.File]::Open($Image, 'Open', 'Read', 'ReadWrite')
try {
    $fatx = [Fatx]::new($stream, $where[0], $where[1])

    $cluster = 1
    if ($parsed.Parts.Count) {
        $entry = $fatx.Find($parsed.Parts)
        if (-not $entry) { throw "not found: $target" }
        if ($List -and -not $entry.IsDir) { throw "not a directory: $target" }
        $cluster = $entry.First
    }

    if ($List) {
        foreach ($item in ($fatx.ReadDir($cluster) | Sort-Object @{e = { -not $_.IsDir } }, Name)) {
            if ($item.IsDir) { '  <DIR>  {0}' -f $item.Name }
            else { '  {0,9:N0}  {1}' -f $item.Size, $item.Name }
        }
    }
    elseif ($Cat) {
        [Text.Encoding]::ASCII.GetString($fatx.ReadFile($entry.First, $entry.Size))
    }
    else {
        if (-not $To) { throw '-Extract requires -To' }
        $bytes = $fatx.ReadFile($entry.First, $entry.Size)
        [IO.File]::WriteAllBytes((New-Item $To -ItemType File -Force).FullName, $bytes)
        "extracted $($bytes.Length) bytes to $To"
    }
} finally { $stream.Dispose() }
