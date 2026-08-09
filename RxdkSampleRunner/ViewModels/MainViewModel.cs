using System.Collections.ObjectModel;
using System.IO;
using System.Text.RegularExpressions;
using Avalonia.Threading;
using RxdkSampleRunner.Models;
using RxdkSampleRunner.Mvvm;
using RxdkSampleRunner.Services;

namespace RxdkSampleRunner.ViewModels;

public sealed class MainViewModel : ObservableObject
{
    private readonly AppSettings _settings;
    private CancellationTokenSource? _cts;

    public MainViewModel()
    {
        _settings = SettingsService.Load();

        RefreshCommand = new AsyncRelayCommand(_ => RunExclusive(_ => Task.Run(RefreshSamples)), _ => !Busy);
        BuildAllCommand = new AsyncRelayCommand(_ => RunExclusive(BuildAllAsync), _ => !Busy && Samples.Count > 0);
        BuildCommand = new AsyncRelayCommand(o => RunExclusive(ct => BuildSampleAsync((SampleItem)o!, ct)), o => !Busy && o is SampleItem);
        LaunchCommand = new AsyncRelayCommand(o => RunExclusive(ct => LaunchXemuAsync((SampleItem)o!, ct)), o => !Busy && o is SampleItem);
        DeployRunCommand = new AsyncRelayCommand(o => RunExclusive(ct => DeployRunAsync((SampleItem)o!, ct)), o => !Busy && o is SampleItem);
        CancelCommand = new RelayCommand(_ => _cts?.Cancel(), _ => Busy);
        BrowseXemuCommand = new AsyncRelayCommand(async _ => { var p = BrowseExeAsync is null ? null : await BrowseExeAsync(); if (p is not null) XemuPath = p; });
        BrowseSamplesCommand = new AsyncRelayCommand(async _ =>
        {
            var p = BrowseFolderAsync is null ? null : await BrowseFolderAsync();
            if (p is not null) { SamplesRoot = p; RefreshSamples(); }
        });

        if (!string.IsNullOrWhiteSpace(_settings.SamplesRoot) && Directory.Exists(_settings.SamplesRoot))
            RefreshSamples();
    }

    // ---- settings-backed, persisted-on-change properties ----
    public string XemuPath { get => _settings.XemuPath; set { _settings.XemuPath = value; OnPropertyChanged(); Persist(); } }
    public string XemuParams { get => _settings.XemuParams; set { _settings.XemuParams = value; OnPropertyChanged(); Persist(); } }
    public string SamplesRoot { get => _settings.SamplesRoot; set { _settings.SamplesRoot = value; OnPropertyChanged(); Persist(); } }
    public string ConsoleIp { get => _settings.ConsoleIp; set { _settings.ConsoleIp = value; OnPropertyChanged(); Persist(); } }
    public string CliPath { get => _settings.CliPath; set { _settings.CliPath = value; OnPropertyChanged(); Persist(); } }
    public string Configuration { get => _settings.Configuration; set { _settings.Configuration = value; OnPropertyChanged(); Persist(); } }

    public ObservableCollection<SampleItem> Samples { get; } = new();

    private string _log = "";
    public string Log { get => _log; set => SetProperty(ref _log, value); }

    private string _status = "Ready";
    public string Status { get => _status; set => SetProperty(ref _status, value); }

    private bool _busy;
    public bool Busy { get => _busy; private set { if (SetProperty(ref _busy, value)) RaiseAllCanExec(); } }

    // File/folder pickers are supplied by the View (which owns the window/StorageProvider).
    public Func<Task<string?>>? BrowseExeAsync;
    public Func<Task<string?>>? BrowseFolderAsync;

    public AsyncRelayCommand RefreshCommand { get; }
    public AsyncRelayCommand BuildAllCommand { get; }
    public AsyncRelayCommand BuildCommand { get; }
    public AsyncRelayCommand LaunchCommand { get; }
    public AsyncRelayCommand DeployRunCommand { get; }
    public RelayCommand CancelCommand { get; }
    public AsyncRelayCommand BrowseXemuCommand { get; }
    public AsyncRelayCommand BrowseSamplesCommand { get; }

    private void RaiseAllCanExec()
    {
        RefreshCommand.RaiseCanExecuteChanged();
        BuildAllCommand.RaiseCanExecuteChanged();
        BuildCommand.RaiseCanExecuteChanged();
        LaunchCommand.RaiseCanExecuteChanged();
        DeployRunCommand.RaiseCanExecuteChanged();
        CancelCommand.RaiseCanExecuteChanged();
    }

    private void Persist() => SettingsService.Save(_settings);

    // ---- log helpers (bounded, UI-thread) ----
    private void Append(string line) => Dispatcher.UIThread.Post(() =>
    {
        var next = _log + line + "\n";
        if (next.Length > 400_000) next = next[^300_000..];
        Log = next;
    });
    private void ClearLog() => Dispatcher.UIThread.Post(() => Log = "");

    // ---- sample discovery ----
    private void RefreshSamples()
    {
        var root = _settings.SamplesRoot;
        var found = new List<SampleItem>();
        if (!string.IsNullOrWhiteSpace(root) && Directory.Exists(root))
        {
            foreach (var vcx in Directory.EnumerateFiles(root, "*.vcxproj", SearchOption.AllDirectories)
                         .Where(p => !p.Replace('\\', '/').Contains("/out/"))
                         .OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
            {
                var dir = Path.GetDirectoryName(vcx)!;
                var item = new SampleItem
                {
                    Name = Path.GetFileNameWithoutExtension(vcx),
                    Category = Path.GetRelativePath(root, dir),
                    Directory = dir,
                    VcxprojPath = vcx,
                };
                item.Rescan();   // detect existing ISO (off the UI thread)
                found.Add(item);
            }
        }
        Dispatcher.UIThread.Post(() =>
        {
            Samples.Clear();
            foreach (var s in found) Samples.Add(s);
            Status = string.IsNullOrWhiteSpace(root) || !Directory.Exists(root)
                ? "Set a valid samples root."
                : $"{Samples.Count} samples  ({Samples.Count(s => s.IsoExists)} with ISO)";
            BuildAllCommand.RaiseCanExecuteChanged();
        });
    }

    // ---- operations ----
    private async Task RunExclusive(Func<CancellationToken, Task> op)
    {
        if (Busy) return;
        Busy = true;
        _cts = new CancellationTokenSource();
        try { await op(_cts.Token); }
        catch (OperationCanceledException) { Append("— cancelled —"); Status = "Cancelled"; }
        catch (Exception ex) { Append("ERROR: " + ex.Message); Status = "Error"; }
        finally { _cts?.Dispose(); _cts = null; Busy = false; }
    }

    private async Task BuildAllAsync(CancellationToken ct)
    {
        ClearLog();
        var msbuild = ToolLocator.ResolveMsbuild(_settings.MsbuildPath);
        if (msbuild is null) { Append("ERROR: MSBuild not found — install VS Build Tools or set the MSBuild path."); Status = "MSBuild not found"; return; }

        int ok = 0, fail = 0, i = 0;
        foreach (var s in Samples.ToList())
        {
            ct.ThrowIfCancellationRequested();
            i++;
            Status = $"Building {i}/{Samples.Count}: {s.Name}  (ok {ok}, fail {fail})";
            var exit = await BuildOneAsync(msbuild, s, ct);
            if (exit == 0) ok++; else fail++;
        }
        Status = $"Build all done — {ok} ok, {fail} failed";
    }

    private Task BuildSampleAsync(SampleItem s, CancellationToken ct)
    {
        ClearLog();
        var msbuild = ToolLocator.ResolveMsbuild(_settings.MsbuildPath);
        if (msbuild is null) { Append("ERROR: MSBuild not found — install VS Build Tools or set the MSBuild path."); Status = "MSBuild not found"; return Task.CompletedTask; }
        return BuildOneAsync(msbuild, s, ct);
    }

    private async Task<int> BuildOneAsync(string msbuild, SampleItem s, CancellationToken ct)
    {
        s.State = BuildState.Building;
        s.IsBusy = true;
        Append($"=== Building {s.Name} ===");
        var args = new[] { s.VcxprojPath, $"/p:Configuration={_settings.Configuration};Platform=Xbox", "/nologo", "/v:minimal" };
        var exit = await ProcessRunner.RunAsync(msbuild, args, s.Directory, Append, ct);
        s.IsBusy = false;
        s.State = exit == 0 ? BuildState.Built : BuildState.Failed;
        Dispatcher.UIThread.Post(() => s.Rescan());
        return exit;
    }

    private async Task LaunchXemuAsync(SampleItem s, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_settings.XemuPath) || !File.Exists(_settings.XemuPath))
        { Status = "Set a valid xemu path first."; Append("ERROR: xemu path not set / not found."); return; }
        var iso = s.IsoFor(_settings.Configuration);
        if (iso is null) { Status = $"{s.Name}: no ISO — build it first."; Append($"ERROR: no ISO for {s.Name} — build it first."); return; }

        ClearLog();  // in-app log is cleared on every new launch
        Status = $"xemu: {s.Name}";

        // xemu.exe is a Windows GUI-subsystem binary: launched with redirected pipes it
        // never wires stdout/stderr, so "-serial stdio" (and xemu's own startup log) never
        // reach us. Give it a real console instead — run it inside a cmd window, where the
        // title's serial console AND xemu's diagnostics show up and stay readable.
        var inner = $"\"{_settings.XemuPath}\" {_settings.XemuParams} -dvd_path \"{iso}\"";
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            FileName = "cmd.exe",
            // /k keeps the console open after xemu exits so the log stays readable.
            Arguments = $"/k title xemu - {s.Name} & {inner}",
            UseShellExecute = false,
            CreateNoWindow = false,   // allocate a visible console window
            WorkingDirectory = Path.GetDirectoryName(_settings.XemuPath) ?? "",
        };
        try
        {
            System.Diagnostics.Process.Start(psi);
            Append($"Launched {s.Name} in a console window — xemu's serial console and startup log appear there.");
            Append("(xemu is a GUI app that can't stream into this pane; the console window shows everything.)");
            Status = $"xemu (console): {s.Name}";
        }
        catch (Exception ex)
        {
            Append($"ERROR: cannot launch xemu console: {ex.Message}");
            Status = "xemu launch failed";
        }
        await Task.CompletedTask;
    }

    private async Task DeployRunAsync(SampleItem s, CancellationToken ct)
    {
        var cli = ToolLocator.ResolveCli(_settings.CliPath);
        if (!File.Exists(cli)) { Append($"ERROR: rxdk CLI not found at {cli}"); Status = "CLI not found"; return; }
        if (!File.Exists(s.ManifestPath)) { Append($"ERROR: no built manifest ({s.ManifestPath}) — build first."); Status = "Not built"; return; }

        ClearLog();
        var deploy = new List<string> { "deploy", "--project-root", s.Directory, "--manifest", s.ManifestPath };
        var run = new List<string> { "run", "--project-root", s.Directory, "--manifest", s.ManifestPath };
        if (!string.IsNullOrWhiteSpace(_settings.ConsoleIp))
        {
            deploy.Add("--console"); deploy.Add(_settings.ConsoleIp);
            run.Add("--console"); run.Add(_settings.ConsoleIp);
        }

        Status = $"Deploying {s.Name} to hardware…";
        if (await ProcessRunner.RunAsync(cli, deploy, s.Directory, Append, ct) != 0) { Status = "Deploy failed"; return; }
        Status = $"Running {s.Name} on hardware…";
        await ProcessRunner.RunAsync(cli, run, s.Directory, Append, ct);
        Status = $"Launched {s.Name} on hardware";
    }

    /// <summary>Split a parameter string into argv, honoring simple double-quoted groups.</summary>
    private static List<string> SplitParams(string s)
    {
        var outv = new List<string>();
        foreach (Match m in Regex.Matches(s ?? "", "\"([^\"]*)\"|(\\S+)"))
            outv.Add(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value);
        return outv;
    }
}
