using System;
using System.IO;
using System.Text.RegularExpressions;

namespace RxdkVs.Package.Services
{
    /// <summary>
    /// The version this extension ships, read from its own manifest (installed as
    /// <c>extension.vsixmanifest</c> beside the assembly), falling back to the assembly version.
    /// Used both to stamp/verify the "Xbox" MSBuild platform and as the compatibility ceiling for
    /// component updates (a component whose live version is newer than this must not be pulled).
    /// </summary>
    internal static class ExtensionInfo
    {
        public static string GetVersion()
        {
            try
            {
                var dir = Path.GetDirectoryName(typeof(ExtensionInfo).Assembly.Location) ?? "";
                var manifest = Path.Combine(dir, "extension.vsixmanifest");
                if (File.Exists(manifest))
                {
                    var text = File.ReadAllText(manifest);
                    var m = Regex.Match(text, "<Identity\\b[^>]*\\bVersion\\s*=\\s*\"([^\"]+)\"");
                    if (m.Success) return m.Groups[1].Value.Trim();
                }
            }
            catch { /* fall through to assembly version */ }
            try { return typeof(ExtensionInfo).Assembly.GetName().Version?.ToString() ?? "0"; }
            catch { return "0"; }
        }
    }
}
