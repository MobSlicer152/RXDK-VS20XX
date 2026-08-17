<#
.SYNOPSIS
Regenerates the boilerplate font/gamepad .rdf descriptors that imported XDK samples
reference but that were never shipped with the sample sources.

.DESCRIPTION
Most samples list Font.rdf / Gamepad.rdf (and the Font9/12/16 and OnlineIconsFont
variants) in their .vcproj, but the files are absent. The build skips missing .rdf
inputs, so the sample links fine and then fails at runtime in Initialize() with
XBAPPERR_MEDIANOTFOUND because Font.xpr / Gamepad.xpr never made it into the ISO.

Every one of these descriptors is boilerplate over art that already lives in
XDKSamples\Common\Media, so they can be reconstructed exactly. Descriptors that
reference per-sample art we do not have (resource.rdf, the CJK fonts,
Xboxdings_24, font18, onlinefont) are reported and skipped.

.PARAMETER DryRun
Report what would be written without creating any files.
#>
[CmdletBinding()]
param(
    [string] $SamplesRoot,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $SamplesRoot) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    $SamplesRoot = Join-Path $repoRoot 'XDKSamples'
}
$SamplesRoot = (Resolve-Path -LiteralPath $SamplesRoot).Path

# name of the referenced .rdf -> the Common\Media art it bundles
$fontRecipes = @{
    'font.rdf'            = @{ Out = 'Font';            Asset = 'Arial_16' }
    'font16.rdf'          = @{ Out = 'Font16';          Asset = 'Arial_16' }
    'font12.rdf'          = @{ Out = 'Font12';          Asset = 'Arial_12' }
    'font9.rdf'           = @{ Out = 'Font9';           Asset = 'Arial_9'  }
    'onlineiconsfont.rdf' = @{ Out = 'OnlineIconsFont'; Asset = 'OnlineIcons' }
}

function New-FontRdf([string] $outName, [string] $fontDir, [string] $asset) {
    @"
// List of resources to bundle.
//
// The output will be a header file (.h) used at compile time,
// and a packed resource file (.xpr) used at runtime.

out_packedresource Media\$outName.xpr
out_error          $outName.err


Texture Font
{
   Source      $fontDir$asset.tga
   Format      D3DFMT_A4R4G4B4
   Levels      1
}

UserData FontData
{
   DataFile $fontDir$asset.abc
}

"@
}

function New-GamepadRdf([string] $textureDir) {
    @"
// List of resources to bundle.
//
// The output will be a header file (.h) used at compile time,
// and a packed resource file (.xpr) used at runtime.

out_packedresource Media\Gamepad.xpr
out_error          Gamepad.err


Texture GamepadTexture
{
   Source $textureDir`Gamepad.tga
   Format D3DFMT_LIN_A8R8G8B8
   Levels 1
}

"@
}

# '..\' repeated far enough to climb from the sample dir back to XDKSamples
function Get-CommonMediaPrefix([string] $sampleDir) {
    $rel = $sampleDir.Substring($SamplesRoot.Length).Trim('\')
    $depth = ($rel -split '\\' | Where-Object { $_ }).Count
    return ('..\' * $depth) + 'Common\Media\'
}

$written = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string]
$skipped = @{}

foreach ($proj in Get-ChildItem $SamplesRoot -Recurse -Filter *.vcproj -File) {
    $dir = $proj.Directory.FullName
    $text = Get-Content $proj.FullName -Raw

    foreach ($m in [regex]::Matches($text, 'RelativePath="\.\\([^"\\]+\.rdf)"')) {
        $name = $m.Groups[1].Value
        $path = Join-Path $dir $name
        if (Test-Path -LiteralPath $path) { continue }
        # several sample dirs hold more than one .vcproj naming the same descriptor
        if (-not $seen.Add($path.ToLowerInvariant())) { continue }

        $key = $name.ToLowerInvariant()
        $commonPrefix = Get-CommonMediaPrefix $dir

        if ($fontRecipes.ContainsKey($key)) {
            $recipe = $fontRecipes[$key]
            # a handful of samples keep their own copy of the art next to the project
            $fontDir = if (Test-Path -LiteralPath (Join-Path $dir "Media\Fonts\$($recipe.Asset).tga")) {
                'Media\Fonts\'
            } else {
                $commonPrefix + 'Fonts\'
            }
            $content = New-FontRdf $recipe.Out $fontDir $recipe.Asset
        }
        elseif ($key -eq 'gamepad.rdf') {
            $textureDir = if (Test-Path -LiteralPath (Join-Path $dir 'Media\Textures\Gamepad.tga')) {
                'Media\Textures\'
            } else {
                $commonPrefix + 'Textures\'
            }
            $content = New-GamepadRdf $textureDir
        }
        else {
            $skipped[$key] = 1 + $skipped[$key]
            continue
        }

        if (-not $DryRun) {
            [System.IO.File]::WriteAllText($path, ($content -replace "`r?`n", "`r`n"))
        }
        $written.Add($path.Substring($SamplesRoot.Length).TrimStart('\'))
    }
}

$verb = if ($DryRun) { 'Would write' } else { 'Wrote' }
"$verb $($written.Count) .rdf files"
$written | Sort-Object | ForEach-Object { "  $_" }

if ($skipped.Count) {
    ''
    'Skipped (needs per-sample art that is not in the tree):'
    $skipped.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
        "  {0,-22} {1} reference(s)" -f $_.Key, $_.Value
    }
}
