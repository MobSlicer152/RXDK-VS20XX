namespace RxdkSampleRunner.Models;

/// <summary>Persisted user settings (JSON in %AppData%\RxdkSampleRunner\settings.json).</summary>
public sealed class AppSettings
{
    /// <summary>Path to the xemu executable.</summary>
    public string XemuPath { get; set; } = "";

    /// <summary>Parameters passed to xemu before "-dvd_path &lt;iso&gt;".</summary>
    public string XemuParams { get; set; } = "-device lpc47m157 -serial stdio";

    /// <summary>Root folder scanned for sample *.vcxproj files.</summary>
    public string SamplesRoot { get; set; } = "";

    /// <summary>Devkit IP/hostname for deploy + run on real hardware (optional).</summary>
    public string ConsoleIp { get; set; } = "";

    /// <summary>Override for the rxdk CLI (default: %ProgramData%\RXDK\engine\Rxdk.Cli.exe).</summary>
    public string CliPath { get; set; } = "";

    /// <summary>Override for MSBuild.exe (default: auto-detected via vswhere).</summary>
    public string MsbuildPath { get; set; } = "";

    /// <summary>Build configuration passed to msbuild (Debug / Release).</summary>
    public string Configuration { get; set; } = "Debug";
}
