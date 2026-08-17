<#
.SYNOPSIS
Shared scrape of the media files a sample loads by name at runtime.

.DESCRIPTION
Dot-sourced by Test-SampleMedia.ps1 (which reports the gaps) and Restore-SampleMedia.ps1
(which fills them). The two must agree on what a sample wants, or the report names files the
restore will not fetch.

Three literal forms appear in the samples, and all three have to be recognised:

  m_Mesh.Create( "Models\\Airplane.xbg" )                 relative to the media root
  XAudioDownloadEffectsImage( "d:\\media\\dsstdfx.bin" )   rooted at the DVD
  sprintf( path, "d:\\%S%S", g_strMediaDir, g_astrFileNames[i] )   built at runtime

The relative form is restricted to extensions that are always a file on disk: a bare
"leaf2.tga" is usually a key into a packed .xpr, and a bare .wav name is often a segment
inside a wave bank, so neither can be trusted without a directory to anchor it. The other two
forms carry an explicit media path, which is evidence enough to check any extension.
#>

# Media a sample loads by path, keyed by lowercase path relative to its media root. Values are
# the literal as written, for reporting.
function Get-SampleWantedMedia {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $SampleDir)

    $wanted = @{}

    $sources = Get-ChildItem $SampleDir -File -Include *.cpp, *.h -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\out\\' }
    if (-not $sources) { return $wanted }

    foreach ($src in $sources) {
        foreach ($line in [IO.File]::ReadAllLines($src.FullName)) {
            foreach ($mm in [regex]::Matches($line, '"([A-Za-z0-9_\\/. -]+\.(?:xpr|xbg|xvu|xpu))"')) {
                $lit = $mm.Groups[1].Value
                if ($lit -match '^[A-Za-z]:') { continue }
                $wanted[(Get-MediaKey $lit)] = $lit
            }

            foreach ($mm in [regex]::Matches($line, '"[dD]:\\{1,2}([A-Za-z0-9_\\/. -]+\.[A-Za-z0-9]{2,4})"')) {
                $lit = $mm.Groups[1].Value
                $key = Get-MediaKey $lit
                if ($key -notmatch '^media/') { continue }
                $wanted[($key -replace '^media/', '')] = "d:\$(Get-MediaDisplay $lit)"
            }
        }
    }

    # The runtime-built form: a prefix literal ending in a separator, plus bare file names that
    # only resolve underneath it. Requiring the prefix is what keeps wave-bank segment names
    # from being read as files.
    $all = ($sources | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    foreach ($pm in [regex]::Matches($all, 'L?"((?:[A-Za-z0-9_. -]+\\\\)+)"')) {
        $prefix = Get-MediaKey $pm.Groups[1].Value
        if ($prefix -notmatch '^media/') { continue }
        $sub = $prefix -replace '^media/', ''
        foreach ($fm in [regex]::Matches($all, 'L"([A-Za-z0-9_. -]+\.(?:wav|wma|bin))"')) {
            $leaf = $fm.Groups[1].Value
            $wanted["$sub$($leaf.ToLowerInvariant())"] = "d:\$(Get-MediaDisplay ($pm.Groups[1].Value + $leaf))"
        }
    }

    return $wanted
}

# Comparison key: separators normalised to '/', C-escaped backslashes collapsed, lowercased.
function Get-MediaKey([string] $literal) {
    return ($literal -replace '\\\\', '/' -replace '\\', '/' -replace '/+', '/').ToLowerInvariant()
}

# Same normalisation, but preserving case and using Windows separators, for messages.
function Get-MediaDisplay([string] $literal) {
    return ($literal -replace '\\\\', '\' -replace '/', '\' -replace '\\+', '\')
}
