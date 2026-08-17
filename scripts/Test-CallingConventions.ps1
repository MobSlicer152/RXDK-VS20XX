<#
.SYNOPSIS
Fails when a library built /Gz-style calls a cdecl libc function as stdcall.

.DESCRIPTION
libd3d8, libdsound, libdmusic, libxnet and libxonline are compiled with
-fdefault-calling-conv=stdcall to match the shipped libraries' /Gz ABI. That flag
also applies to libc prototypes, which carry no explicit convention, so each of
those libraries force-includes a site/cdecl_libc.h that pins the libc functions it
uses back to __cdecl. Any function missing from that list compiles as stdcall.

The linker cannot catch it: clang's default-calling-conv does not decorate the
symbol, so the call still binds to plain _malloc and only misbehaves at runtime.
The caller emits a compensating `sub esp,N` after the call for the arguments it
believes the callee popped, so ESP is left low and the epilogue returns through
the wrong stack slot -- the thread jumps to whatever the saved EBP held.

This finds that pattern in a linked title: a call to a known cdecl libc symbol
followed immediately by `sub esp,N`. Calls to genuinely stdcall functions also
compensate, which is correct, so the check is scoped to libc names.
#>
[CmdletBinding()]
param(
    # Linked title(s) to check. A title pulls in every library it uses.
    [Parameter(Mandatory)] [string[]] $Exe
)

$ErrorActionPreference = 'Stop'

# The cdecl runtime surface. Names as the i386 assembler shows them (leading _).
$libc = '^_(' + (@(
    'malloc', 'free', 'calloc', 'realloc',
    'memcpy', 'memmove', 'memset', 'memcmp', 'memchr',
    'str[a-z]+', 'wcs[a-z]+',
    'sprintf', 'snprintf', 'vsprintf', 'vsnprintf', 'sscanf',
    'qsort', 'bsearch', 'rand', 'srand',
    'abs', 'labs', 'atoi', 'atol', 'atof', 'strtol', 'strtoul',
    'pow', 'sqrt', 'sin', 'cos', 'tan', 'acos', 'asin', 'atan', 'atan2',
    'ceil', 'floor', 'fabs', 'fabsf', 'fmod', 'log', 'log10', 'log10f', 'exp', 'expf',
    'tolower', 'toupper', 'assert', '__assert_func'
) -join '|') + ')$'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -property installationPath
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC" -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Hostx64\\x64\\|\\Hostx86\\x86\\' } | Select-Object -First 1
if (-not $dumpbin) { throw "dumpbin.exe not found under $vs." }

$violations = New-Object System.Collections.Generic.List[object]

foreach ($path in $Exe) {
    if (-not (Test-Path $path)) { Write-Warning "skipping missing $path"; continue }
    $name = Split-Path $path -Leaf
    Write-Host "checking $name ..."

    $asm = Join-Path $env:TEMP ($name + '.ccheck.asm')
    & $dumpbin.FullName /nologo /disasm:nobytes $path > $asm

    $fn = '?'; $prev = ''
    foreach ($line in [IO.File]::ReadLines($asm)) {
        if ($line -match '^([_\?\$][^\s:]*):$') { $fn = $Matches[1]; $prev = ''; continue }
        if ($line -match '^\s*[0-9A-F]{8}: .*\bsub\s+esp,' -and $prev -match 'call\s+(\S+)\s*$') {
            if ($Matches[1] -match $libc) {
                $violations.Add([pscustomobject]@{ Title = $name; Function = $fn; Callee = $Matches[1] })
            }
        }
        if ($line -match '^\s*[0-9A-F]{8}: ') { $prev = $line }
    }
}

if ($violations.Count -eq 0) {
    Write-Host "OK: no libc call compiled as stdcall."
    exit 0
}

Write-Host ""
Write-Host "FAIL: $($violations.Count) libc call(s) compiled as stdcall." -ForegroundColor Red
$violations | Group-Object Callee | Sort-Object Count -Descending | ForEach-Object {
    "  {0,-14} {1} site(s)" -f $_.Name, $_.Count
    $_.Group | Select-Object -First 8 | ForEach-Object { "      in {0} ({1})" -f $_.Function, $_.Title }
}
Write-Host ""
Write-Host "Add the callee to the owning library's site/cdecl_libc.h."
exit 1
