using System.IO;
using RxdkSampleRunner.Mvvm;

namespace RxdkSampleRunner.Models;

public enum BuildState { None, Building, Built, Failed }

/// <summary>A discovered sample (one .vcxproj) plus its cached build/ISO state.</summary>
public sealed class SampleItem : ObservableObject
{
    public required string Name { get; init; }        // vcxproj base name
    public required string Category { get; init; }     // relative folder, for grouping/display
    public required string Directory { get; init; }    // folder containing the .vcxproj
    public required string VcxprojPath { get; init; }

    public string OutDir => Path.Combine(Directory, "out");

    /// <summary>Build-generated manifest used for deploy/run on hardware (out\rxdk.manifest.json).</summary>
    public string ManifestPath => Path.Combine(OutDir, "rxdk.manifest.json");

    // Cached ISO locations, filled by Rescan(). The native-.vcxproj build packs to
    // out\<Config>\XISO\<name>.iso; the manifest/rxdk.project.json flow uses out\XISO.
    private string? _isoDebug, _isoRelease, _isoAny;

    /// <summary>Best ISO to launch for a configuration (falls back to any built ISO).</summary>
    public string? IsoFor(string config) =>
        (string.Equals(config, "Release", StringComparison.OrdinalIgnoreCase) ? _isoRelease : _isoDebug) ?? _isoAny;

    public bool IsoExists => _isoAny is not null;

    private BuildState _state;
    public BuildState State
    {
        get => _state;
        set { if (SetProperty(ref _state, value)) OnPropertyChanged(nameof(IsoStatusText)); }
    }

    private bool _busy;
    public bool IsBusy { get => _busy; set => SetProperty(ref _busy, value); }

    /// <summary>Rescan the output tree for built ISOs (cheap — only the known XISO dirs).</summary>
    public void Rescan()
    {
        var flat = FirstIso(Path.Combine(OutDir, "XISO"));
        _isoDebug = FirstIso(Path.Combine(OutDir, "Debug", "XISO")) ?? flat;
        _isoRelease = FirstIso(Path.Combine(OutDir, "Release", "XISO")) ?? flat;
        _isoAny = _isoDebug ?? _isoRelease ?? flat;
        OnPropertyChanged(nameof(IsoExists));
        OnPropertyChanged(nameof(IsoStatusText));
    }

    private static string? FirstIso(string dir) =>
        System.IO.Directory.Exists(dir)
            ? System.IO.Directory.EnumerateFiles(dir, "*.iso").FirstOrDefault()
            : null;

    public string IsoStatusText => State switch
    {
        BuildState.Building => "building…",
        BuildState.Failed => "build failed",
        _ => IsoExists ? "ISO ready" : "not built",
    };
}
