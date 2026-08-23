using System;
using System.IO;
using System.Reflection;

namespace RxdkVs.Package.Services
{
    /// <summary>
    /// Copies the net8 engine (Rxdk.Cli/Rxdk.Dap + their deps) that ships bundled in the VSIX under
    /// <c>tools\</c> into <c>%ProgramData%\RXDK\engine</c> — the location the RXDK build props
    /// (<c>RxdkCli</c>) and the debug launcher (<c>Rxdk.Dap.exe</c>) resolve. Without this a fresh
    /// install has an empty engine dir, so a sample won't compile or debug even after Install
    /// Prerequisites (the tool window uses the bundled copy directly, but MSBuild/the launcher
    /// don't). Only copies files that are missing, a different size, or older than the bundled
    /// copy, so it also refreshes the engine after a VSIX upgrade without clobbering a newer
    /// dev-published one. Best-effort: never throws, never blocks package load.
    /// </summary>
    internal static class EngineStager
    {
        public static void StageBundledEngine()
        {
            try
            {
                var vsixDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(vsixDir)) return;
                var src = Path.Combine(vsixDir, "tools");
                if (!Directory.Exists(src)) return; // dev/F5 build without the bundle

                var dest = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "RXDK", "engine");
                Directory.CreateDirectory(dest);

                foreach (var srcFile in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
                {
                    var rel = srcFile.Substring(src.Length)
                        .TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    var destFile = Path.Combine(dest, rel);
                    try
                    {
                        var s = new FileInfo(srcFile);
                        var d = new FileInfo(destFile);
                        if (d.Exists && d.Length == s.Length && d.LastWriteTimeUtc >= s.LastWriteTimeUtc)
                            continue; // already current
                        Directory.CreateDirectory(Path.GetDirectoryName(destFile));
                        File.Copy(srcFile, destFile, overwrite: true);
                    }
                    catch { /* locked (engine running) or transient — keep the existing copy */ }
                }
            }
            catch { /* never block package load on engine staging */ }
        }
    }
}
