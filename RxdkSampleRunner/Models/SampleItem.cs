using System.IO;
using RxdkSampleRunner.Mvvm;

namespace RxdkSampleRunner.Models;

public enum BuildState { None, Building, Built, Failed }

/// <summary>A discovered sample (one .vcxproj) plus its live build/ISO state.</summary>
public sealed class SampleItem : ObservableObject
{
    public required string Name { get; init; }        // vcxproj base name
    public required string Category { get; init; }     // relative folder, for grouping/display
    public required string Directory { get; init; }    // folder containing the .vcxproj
    public required string VcxprojPath { get; init; }

    /// <summary>Where the packed ISO lands: &lt;dir&gt;\out\XISO\*.iso.</summary>
    public string XisoDir => Path.Combine(Directory, "out", "XISO");

    /// <summary>The built ISO path, if one exists (any *.iso under out\XISO).</summary>
    public string? IsoPath =>
        System.IO.Directory.Exists(XisoDir)
            ? System.IO.Directory.EnumerateFiles(XisoDir, "*.iso").FirstOrDefault()
            : null;

    public bool IsoExists => IsoPath is not null;

    /// <summary>The build-generated manifest used for deploy/run on hardware.</summary>
    public string ManifestPath => Path.Combine(Directory, "out", "rxdk.manifest.json");

    private BuildState _state;
    public BuildState State { get => _state; set { if (SetProperty(ref _state, value)) Refresh(); } }

    private bool _busy;
    public bool IsBusy { get => _busy; set => SetProperty(ref _busy, value); }

    /// <summary>Raise change notifications for the computed ISO properties after a build.</summary>
    public void Refresh()
    {
        OnPropertyChanged(nameof(IsoExists));
        OnPropertyChanged(nameof(IsoPath));
        OnPropertyChanged(nameof(IsoStatusText));
    }

    public string IsoStatusText => State switch
    {
        BuildState.Building => "building…",
        BuildState.Failed => "build failed",
        _ => IsoExists ? "ISO ready" : "not built",
    };
}
