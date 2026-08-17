<#
.SYNOPSIS
Reports SSE2-and-later instruction encodings inside the code sections of static libraries.

.DESCRIPTION
The Xbox CPU is a Pentium III: SSE1 and MMX only, no SSE2. A library built for a newer
baseline links and packs fine and then raises an invalid-opcode exception on hardware, so
this is worth checking whenever the toolchain or its target flags move.

Scanning raw archive bytes is useless here - a multi-megabyte .lib holds string tables,
symbol tables, relocations and debug data, and random byte pairs match any short opcode
pattern often enough to drown the signal. This walks the archive member by member, parses
each COFF object's section table, and searches only sections flagged IMAGE_SCN_CNT_CODE.

.PARAMETER LibDir
Directories of .lib files to scan. Defaults to the installed SDK's debug and release dirs.
#>
[CmdletBinding()]
param(
    [string[]] $LibDir = @(
        "C:\ProgramData\RXDK\sdk\lib\debug",
        "C:\ProgramData\RXDK\sdk\lib\release"
    ),
    [switch] $ShowBytes
)

$ErrorActionPreference = 'Stop'

$IMAGE_SCN_CNT_CODE = 0x00000020
$IMAGE_FILE_MACHINE_I386 = 0x014C

# Encodings that exist only in SSE2 or later. The F2 0F group is scalar-double arithmetic
# (movsd/addsd/mulsd/subsd/divsd/sqrtsd/cvtsi2sd); the 66 0F group is packed-integer /
# double moves (movdqa/movdqu/movq/pxor). SSE1 uses F3 0F and bare 0F for its equivalents.
$patterns = @(
    @{ Name = 'F2 0F xx (scalar double)'; Rx = "\xF2\x0F[\x10\x11\x58\x59\x5C\x5E\x51\x2A]" },
    @{ Name = '66 0F xx (packed int/dbl)'; Rx = "\x66\x0F[\x6F\x7F\xD6\xEF]" }
)

$enc = [Text.Encoding]::GetEncoding(28591)  # latin1: 1 byte -> 1 char, no lossy mapping

function Get-CodeSections([byte[]] $data, [int] $base, [int] $len) {
    $out = @()
    if ($len -lt 20) { return $out }
    $machine = [BitConverter]::ToUInt16($data, $base)
    # Import objects start 0x0000 0xFFFF and carry no section table.
    if ($machine -ne $IMAGE_FILE_MACHINE_I386) { return $out }

    $numSections = [BitConverter]::ToUInt16($data, $base + 2)
    $optSize     = [BitConverter]::ToUInt16($data, $base + 16)
    $secStart    = $base + 20 + $optSize

    for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secStart + ($i * 40)
        if ($s + 40 -gt $base + $len) { break }
        $name = ($enc.GetString($data, $s, 8)).TrimEnd([char]0)
        $sizeRaw = [BitConverter]::ToInt32($data, $s + 16)
        $ptrRaw  = [BitConverter]::ToInt32($data, $s + 20)
        $chars   = [BitConverter]::ToUInt32($data, $s + 36)
        if (($chars -band $IMAGE_SCN_CNT_CODE) -eq 0) { continue }
        if ($ptrRaw -le 0 -or $sizeRaw -le 0) { continue }
        if ($base + $ptrRaw + $sizeRaw -gt $data.Length) { continue }
        $out += [pscustomobject]@{ Name = $name; Offset = $base + $ptrRaw; Size = $sizeRaw }
    }
    return $out
}

foreach ($dir in $LibDir) {
    if (-not (Test-Path $dir)) { "=== $dir  (missing)"; continue }
    "=== $dir"
    $dirHits = 0

    foreach ($lib in Get-ChildItem $dir -Filter *.lib | Sort-Object Name) {
        $data = [IO.File]::ReadAllBytes($lib.FullName)
        if ($data.Length -lt 8) { continue }

        $codeBytes = 0
        $hits = @()
        $pos = 8  # past "!<arch>\n"

        while ($pos + 60 -le $data.Length) {
            $nameField = ($enc.GetString($data, $pos, 16)).Trim()
            $sizeField = ($enc.GetString($data, $pos + 48, 10)).Trim()
            $size = 0
            if (-not [int]::TryParse($sizeField, [ref]$size)) { break }
            $memberAt = $pos + 60

            # linker members ("/", "//") and the longnames table hold no code
            if ($nameField -ne '/' -and $nameField -ne '//' -and $size -gt 0) {
                foreach ($sec in Get-CodeSections $data $memberAt $size) {
                    $codeBytes += $sec.Size
                    $text = $enc.GetString($data, $sec.Offset, $sec.Size)
                    foreach ($p in $patterns) {
                        foreach ($m in [regex]::Matches($text, $p.Rx)) {
                            $hits += [pscustomobject]@{
                                Member  = $nameField
                                Section = $sec.Name
                                Pattern = $p.Name
                                At      = $sec.Offset + $m.Index
                            }
                        }
                    }
                }
            }

            $pos = $memberAt + $size
            if ($size % 2 -eq 1) { $pos++ }  # members are 2-byte aligned
        }

        if ($hits.Count -gt 0) {
            $dirHits += $hits.Count
            "  {0,-22} {1} hit(s) in {2:N0} bytes of code" -f $lib.Name, $hits.Count, $codeBytes
            foreach ($h in $hits) {
                "      {0} [{1}] {2}" -f $h.Member, $h.Section, $h.Pattern
                if ($ShowBytes) {
                    $from = [Math]::Max(0, $h.At - 8)
                    $slice = $data[$from..([Math]::Min($data.Length - 1, $h.At + 8))]
                    "        " + (($slice | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
                }
            }
        }
    }

    if ($dirHits -eq 0) {
        "  clean - no SSE2+ encodings in any code section"
    }
    else {
        ''
        "  NOTE: these are byte matches, not decoded instructions. Re-run with -ShowBytes and"
        "  read the stream: a 0xF2 that is really the ModRM byte of an SSE1 op (0F 28 F2 movaps,"
        "  0F 59 F2 mulps) or a jump displacement (75 F2) is followed by the *next* instruction's"
        "  0F and matches this pattern without any SSE2 being present."
    }
}
