<#
.SYNOPSIS
Writes a small file into the FATX filesystem of the xemu Xbox HDD image, creating any
missing parent directories.

.DESCRIPTION
Needed because some BIOS behaviour is driven by files on the console's disk rather than by
anything we build - Cerbios only loads the debug monitor when E:\Cerbios\Cerbios.ini enables
it - and there is no way to put a file there from the host without writing FATX directly.

Deliberately narrow: it allocates fresh clusters for new files and will not grow a directory
beyond its existing cluster chain. Overwriting an existing file is allowed only when the new
contents still fit the clusters already allocated to it. Back up the image before using this.

.EXAMPLE
Write-XemuHddFile.ps1 -Path 'E:\Cerbios\Cerbios.ini' -Content "[Config]`r`nDebug = True`r`n"
#>
[CmdletBinding()]
param(
    [string] $Image = 'D:\Git\xemu-devkit\roms\Original Xbox HDD Image.bin',
    [Parameter(Mandatory)][string] $Path,
    [string] $Content,
    [string] $Source
)

$ErrorActionPreference = 'Stop'

if (-not $Content -and -not $Source) { throw 'pass -Content or -Source' }
$bytes = if ($Source) { [IO.File]::ReadAllBytes($Source) } else { [Text.Encoding]::ASCII.GetBytes($Content) }

if (Get-Process xemu -ErrorAction SilentlyContinue) { throw 'xemu is running and holds the image locked' }

$PartitionMap = @{
    'C' = @(0x8CA80000L, 0x1F400000L)
    'E' = @(0xABE80000L, 0x01312D6000L)
}

$drive = $Path.Substring(0, 1).ToUpper()
if (-not $PartitionMap.ContainsKey($drive)) { throw "unmapped drive '$drive'" }
$parts = ($Path.Substring(2).Trim('\')) -split '\\'
if ($parts.Count -lt 1 -or -not $parts[-1]) { throw "no filename in '$Path'" }

$offset = $PartitionMap[$drive][0]
$length = $PartitionMap[$drive][1]

# FATX timestamps pack date in the high word, time in the low, with years since 2000
function Get-FatxTime {
    $n = Get-Date
    $date = (($n.Year - 2000) -shl 9) -bor ($n.Month -shl 5) -bor $n.Day
    $time = ($n.Hour -shl 11) -bor ($n.Minute -shl 5) -bor [int]($n.Second / 2)
    return [uint32](([uint32]$date -shl 16) -bor [uint32]$time)
}

$fs = [IO.File]::Open($Image, 'Open', 'ReadWrite', 'None')
try {
    $fs.Position = $offset
    $header = [byte[]]::new(4096)
    $null = $fs.Read($header, 0, 4096)
    if ([Text.Encoding]::ASCII.GetString($header, 0, 4) -ne 'FATX') { throw 'no FATX magic' }

    $clusterBytes = [int]([BitConverter]::ToUInt32($header, 8) * 512)
    $fatCopies    = [int][BitConverter]::ToUInt16($header, 12)
    if ($fatCopies -ne 1) { throw "unsupported: $fatCopies FAT copies" }
    $clusters   = [long]($length / $clusterBytes)
    $entryBytes = if ($clusters -ge 0xFFF0) { 4 } else { 2 }
    $fatOffset  = $offset + 4096
    $fatBytes   = [long][Math]::Ceiling(($clusters * $entryBytes) / 4096.0) * 4096
    $dataStart  = $fatOffset + $fatBytes

    $fat = [byte[]]::new($fatBytes)
    $fs.Position = $fatOffset
    $got = 0
    while ($got -lt $fatBytes) {
        $n = $fs.Read($fat, $got, [int][Math]::Min(1MB, $fatBytes - $got)); if ($n -le 0) { break }; $got += $n
    }

    $EOC = if ($entryBytes -eq 2) { 0xFFFF } else { 0xFFFFFFFFL }

    function Get-Entry([int]$index) {
        if ($entryBytes -eq 2) { return [long][BitConverter]::ToUInt16($fat, $index * 2) }
        return [long][BitConverter]::ToUInt32($fat, $index * 4)
    }
    function Set-Entry([int]$index, [long]$value) {
        $raw = if ($entryBytes -eq 2) { [BitConverter]::GetBytes([uint16]$value) } else { [BitConverter]::GetBytes([uint32]$value) }
        [Array]::Copy($raw, 0, $fat, $index * $entryBytes, $entryBytes)
        $fs.Position = $fatOffset + ($index * $entryBytes)
        $fs.Write($raw, 0, $entryBytes)
    }
    function Get-Next([int]$c) {
        $v = Get-Entry $c
        if ($entryBytes -eq 2 -and $v -ge 0xFFF8) { return -1 }
        if ($entryBytes -eq 4 -and ($v -ge 0xFFFFFFF8L -or $v -eq 0)) { return -1 }
        return [int]$v
    }
    function New-Chain([int]$count) {
        $found = @()
        for ($i = 2; $i -lt $clusters -and $found.Count -lt $count; $i++) {
            if ((Get-Entry $i) -eq 0) { $found += $i }
        }
        if ($found.Count -lt $count) { throw 'no free clusters' }
        for ($k = 0; $k -lt $found.Count; $k++) {
            Set-Entry $found[$k] $(if ($k -eq $found.Count - 1) { $EOC } else { [long]$found[$k + 1] })
        }
        return $found
    }
    function Read-Cluster([int]$c) {
        $fs.Position = $dataStart + ([long]($c - 1) * $clusterBytes)
        $buf = [byte[]]::new($clusterBytes)
        $r = 0
        while ($r -lt $clusterBytes) { $k = $fs.Read($buf, $r, $clusterBytes - $r); if ($k -le 0) { break }; $r += $k }
        return $buf
    }
    function Write-Cluster([int]$c, [byte[]]$data) {
        $fs.Position = $dataStart + ([long]($c - 1) * $clusterBytes)
        $fs.Write($data, 0, $clusterBytes)
    }

    # locate a named entry anywhere in a directory's cluster chain
    function Find-Entry([int]$dirCluster, [string]$name) {
        $c = $dirCluster
        while ($c -gt 0) {
            $buf = Read-Cluster $c
            for ($i = 0; $i -lt $clusterBytes; $i += 64) {
                $len = $buf[$i]
                if ($len -eq 0x00 -or $len -eq 0xFF) { return $null }
                if ($len -eq 0xE5 -or $len -gt 42) { continue }
                if ([Text.Encoding]::ASCII.GetString($buf, $i + 2, $len) -ieq $name) {
                    return [pscustomobject]@{
                        Cluster = $c; Offset = $i
                        First   = [int][BitConverter]::ToUInt32($buf, $i + 0x2C)
                        Size    = [long][BitConverter]::ToUInt32($buf, $i + 0x30)
                        IsDir   = [bool]($buf[$i + 1] -band 0x10)
                    }
                }
            }
            $c = Get-Next $c
        }
        return $null
    }

    function Add-Entry([int]$dirCluster, [string]$name, [byte]$attr, [int]$first, [long]$size) {
        $c = $dirCluster
        while ($c -gt 0) {
            $buf = Read-Cluster $c
            for ($i = 0; $i -lt $clusterBytes; $i += 64) {
                $len = $buf[$i]
                if ($len -ne 0x00 -and $len -ne 0xFF) { continue }
                # free slot: the rest of the cluster stays as it was, so the next slot is
                # still a terminator and the directory does not gain phantom entries
                $rec = [byte[]]::new(64)
                for ($k = 0; $k -lt 64; $k++) { $rec[$k] = 0xFF }
                $rec[0] = [byte]$name.Length
                $rec[1] = $attr
                [Array]::Copy([Text.Encoding]::ASCII.GetBytes($name), 0, $rec, 2, $name.Length)
                [Array]::Copy([BitConverter]::GetBytes([uint32]$first), 0, $rec, 0x2C, 4)
                [Array]::Copy([BitConverter]::GetBytes([uint32]$size), 0, $rec, 0x30, 4)
                $stamp = [BitConverter]::GetBytes((Get-FatxTime))
                [Array]::Copy($stamp, 0, $rec, 0x34, 4)
                [Array]::Copy($stamp, 0, $rec, 0x38, 4)
                [Array]::Copy($stamp, 0, $rec, 0x3C, 4)
                $fs.Position = $dataStart + ([long]($c - 1) * $clusterBytes) + $i
                $fs.Write($rec, 0, 64)
                return
            }
            $c = Get-Next $c
        }
        throw "no free slot in directory (growing a directory is not supported)"
    }

    # walk to the parent, creating directories as needed
    $cluster = 1
    for ($d = 0; $d -lt $parts.Count - 1; $d++) {
        $seg = $parts[$d]
        $entry = Find-Entry $cluster $seg
        if ($entry) {
            if (-not $entry.IsDir) { throw "$seg is a file, not a directory" }
            $cluster = $entry.First
            "exists: $seg"
            continue
        }
        $new = (New-Chain 1)[0]
        $blank = [byte[]]::new($clusterBytes)
        for ($k = 0; $k -lt $clusterBytes; $k++) { $blank[$k] = 0xFF }
        Write-Cluster $new $blank
        Add-Entry $cluster $seg 0x10 $new 0
        "created dir: $seg (cluster $new)"
        $cluster = $new
    }

    $leaf = $parts[-1]
    $needed = [int][Math]::Max(1, [Math]::Ceiling($bytes.Length / [double]$clusterBytes))
    $existing = Find-Entry $cluster $leaf

    if ($existing) {
        $have = 0; $c = $existing.First
        while ($c -gt 0) { $have++; $c = Get-Next $c }
        if ($needed -gt $have) { throw "existing file has $have cluster(s), need $needed" }
        $chain = @(); $c = $existing.First
        while ($c -gt 0 -and $chain.Count -lt $needed) { $chain += $c; $c = Get-Next $c }
        $fs.Position = $dataStart + ([long]($existing.Cluster - 1) * $clusterBytes) + $existing.Offset + 0x30
        $fs.Write([BitConverter]::GetBytes([uint32]$bytes.Length), 0, 4)
        "overwrote existing $leaf"
    } else {
        $chain = New-Chain $needed
        Add-Entry $cluster $leaf 0x20 $chain[0] $bytes.Length
        "created file: $leaf (cluster $($chain[0]), $($bytes.Length) bytes)"
    }

    for ($k = 0; $k -lt $chain.Count; $k++) {
        $slice = [byte[]]::new($clusterBytes)
        $from = $k * $clusterBytes
        $take = [Math]::Min($clusterBytes, $bytes.Length - $from)
        if ($take -gt 0) { [Array]::Copy($bytes, $from, $slice, 0, $take) }
        Write-Cluster $chain[$k] $slice
    }

    $fs.Flush($true)
    "wrote $Path"
} finally { $fs.Dispose() }
