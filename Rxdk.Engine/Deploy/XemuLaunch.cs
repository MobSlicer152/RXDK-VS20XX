using System.Text.RegularExpressions;
using Rxdk.Engine.Build;
using Rxdk.Engine.Model;
using Rxdk.Engine.Platform;

namespace Rxdk.Engine.Deploy;

/// <summary>
/// Boots a compiled ISO in the xemu emulator (no debugging). C# port of RXDK-VSCode
/// xemuLaunch.ts. xemu runs until the user closes it; its stdout/stderr stream to the log, so
/// with the default params (-device lpc47m157 -serial stdio) the Xbox debug serial shows up
/// there as the title's console output.
/// </summary>
public static class XemuLaunch
{
    /// <summary>Default xemu parameters — the lpc47m157 super-I/O + -serial stdio route the
    /// Xbox serial console to xemu's stdout, which we stream back to the caller.</summary>
    public const string DefaultParams = "-device lpc47m157 -serial stdio";

    public sealed class LaunchOptions
    {
        public required string ProjectRoot { get; init; }
        public required RxdkProjectManifest Manifest { get; init; }
        public required string XemuPath { get; init; }
        public string? XemuParams { get; init; }
        public Action<string>? Log { get; init; }
    }

    public static async Task<LaunchResult> LaunchXemuAsync(LaunchOptions opts, CancellationToken ct = default)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(opts.XemuPath))
                return LaunchResult.Fail("No xemu path set — configure the xemu path in Options.");
            if (!File.Exists(opts.XemuPath))
                return LaunchResult.Fail($"xemu not found at: {opts.XemuPath}");

            var outDir = SdkLayout.GetProjectOutDir(opts.ProjectRoot, opts.Manifest);
            var iso = Path.Combine(outDir, "XISO", $"{opts.Manifest.Name}.iso");
            if (!File.Exists(iso))
                return LaunchResult.Fail($"Built ISO not found: {iso} — build the project first.");

            var paramsStr = string.IsNullOrWhiteSpace(opts.XemuParams) ? DefaultParams : opts.XemuParams!.Trim();
            var args = new List<string>(SplitParams(paramsStr)) { "-dvd_path", iso };

            opts.Log?.Invoke($"Launching xemu: {Path.GetFileName(iso)}");
            var r = await ProcessRunner.RunStreamedAsync(opts.XemuPath, args, opts.Log, ct: ct);
            if (!r.Success)
                return LaunchResult.Fail($"xemu exited with code {r.ExitCode}");
            return LaunchResult.Success;
        }
        catch (Exception err)
        {
            return LaunchResult.Fail(err.Message);
        }
    }

    /// <summary>Split a parameter string into argv, honoring simple double-quoted groups.</summary>
    internal static List<string> SplitParams(string s)
    {
        var outv = new List<string>();
        foreach (Match g in Regex.Matches(s, "\"([^\"]*)\"|(\\S+)"))
            outv.Add(g.Groups[1].Success ? g.Groups[1].Value : g.Groups[2].Value);
        return outv;
    }
}
