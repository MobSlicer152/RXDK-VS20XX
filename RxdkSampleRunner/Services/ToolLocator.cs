using System.Diagnostics;
using System.IO;

namespace RxdkSampleRunner.Services;

/// <summary>Locates MSBuild (via vswhere) and the staged rxdk CLI, honoring user overrides.</summary>
public static class ToolLocator
{
    /// <summary>Default staged rxdk CLI: %ProgramData%\RXDK\engine\Rxdk.Cli.exe.</summary>
    public static string DefaultCli => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "RXDK", "engine", "Rxdk.Cli.exe");

    public static string ResolveCli(string? overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return overridePath!;
        return DefaultCli;
    }

    /// <summary>Find MSBuild.exe via vswhere (latest install with the MSBuild component).</summary>
    public static string? ResolveMsbuild(string? overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return overridePath;

        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var vswhere = Path.Combine(pf86, "Microsoft Visual Studio", "Installer", "vswhere.exe");
        if (!File.Exists(vswhere)) return null;

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = vswhere,
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in new[]
                     {
                         "-latest", "-prerelease",
                         "-requires", "Microsoft.Component.MSBuild",
                         "-find", @"MSBuild\**\Bin\MSBuild.exe"
                     })
                psi.ArgumentList.Add(a);

            using var p = Process.Start(psi);
            if (p is null) return null;
            var outText = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            var line = outText.Split('\n').Select(s => s.Trim()).FirstOrDefault(s => s.Length > 0);
            return (line is not null && File.Exists(line)) ? line : null;
        }
        catch { return null; }
    }
}
