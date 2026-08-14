using Rxdk.Engine.Platform;

namespace Rxdk.Engine.Build;

/// <summary>A file to stage into the ISO/deploy tree at a project-relative destination.</summary>
public sealed record StageFileEntry(string Source, string RelativeDest);

/// <summary>
/// Packs a .xbe (+ staged files) into an XISO via the xdvdfs host tool, and resolves a
/// project's deployPaths into stage entries. C# port of RXDK-VSCode packXiso.ts +
/// resolveDeployPaths (xboxDeploy.ts).
/// </summary>
public static class PackXiso
{
    /// <summary>Pack a .xbe (+ any staged files) into an XISO. Returns the .iso path.</summary>
    public static async Task<string> PackAsync(
        string inputXbe, string projectName, string outDir, string toolPath,
        IReadOnlyList<StageFileEntry>? stageFiles = null, Action<string>? log = null,
        CancellationToken ct = default)
    {
        var xbe = Path.GetFullPath(inputXbe);
        if (!File.Exists(xbe)) throw new FileNotFoundException($"xdvdfs: input XBE not found: {xbe}");
        if (string.IsNullOrEmpty(toolPath)) throw new ArgumentException("xdvdfs: toolPath required");

        var resolvedOutDir = Path.GetFullPath(string.IsNullOrEmpty(outDir) ? Path.GetDirectoryName(xbe)! : outDir);
        var packDir = Path.Combine(resolvedOutDir, "Build", projectName);
        var defaultXbe = Path.Combine(packDir, "default.xbe");
        var outputIso = Path.GetFullPath(Path.Combine(resolvedOutDir, "XISO", $"{projectName}.iso"));

        Directory.CreateDirectory(packDir);
        Directory.CreateDirectory(Path.GetDirectoryName(outputIso)!);
        File.Copy(xbe, defaultXbe, overwrite: true);

        var packRoot = Path.GetFullPath(packDir + Path.DirectorySeparatorChar);
        foreach (var entry in stageFiles ?? Array.Empty<StageFileEntry>())
        {
            var src = Path.GetFullPath(entry.Source);
            if (!File.Exists(src)) throw new FileNotFoundException($"StageFile source not found: {src}");
            var dest = Path.GetFullPath(Path.Combine(packDir, entry.RelativeDest.Replace('/', Path.DirectorySeparatorChar)));
            // xdvdfs only packs packDir, so a destination that resolves outside it would be
            // copied but silently left out of the image.
            if (!dest.StartsWith(packRoot, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(
                    $"StageFile destination escapes the image root: \"{entry.RelativeDest}\" -> {dest}");
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.Copy(src, dest, overwrite: true);
        }

        var r = await ProcessRunner.RunStreamedAsync(toolPath, new[] { "pack", packDir, outputIso }, log, ct: ct);
        if (!r.Success) throw new InvalidOperationException($"xdvdfs pack failed (exit {r.ExitCode})");
        return outputIso;
    }

    /// <summary>
    /// Resolve a manifest's deployPaths (project-relative files/dirs) into flat stage entries.
    /// Directories are walked recursively. Missing paths warn and are skipped.
    /// </summary>
    public static List<StageFileEntry> ResolveDeployPaths(
        string projectRoot, IReadOnlyList<string>? deployPaths, Action<string>? log = null)
    {
        var outList = new List<StageFileEntry>();
        foreach (var relPath in deployPaths ?? Enumerable.Empty<string>())
        {
            if (string.IsNullOrWhiteSpace(relPath)) continue;
            var cleanRel = relPath.Replace('\\', '/').TrimEnd('/');
            var localPath = Path.Combine(projectRoot, cleanRel.Replace('/', Path.DirectorySeparatorChar));

            // The destination is always inside the image/remote root: a deploy path may reach
            // outside the project dir (imported XDK samples use "..\media"), but its files still
            // land under that directory's name, matching the XDK deployment tool.
            var destRel = string.Join('/', cleanRel.Split('/')
                .Where(s => s.Length > 0 && s != "." && s != ".."));
            if (destRel.Length == 0)
                destRel = Path.GetFileName(localPath.TrimEnd(Path.DirectorySeparatorChar));

            if (File.Exists(localPath))
            {
                outList.Add(new StageFileEntry(localPath, destRel));
                continue;
            }
            if (!Directory.Exists(localPath))
            {
                log?.Invoke($"Warning: deployPaths: not found {localPath}");
                continue;
            }

            var files = Directory.EnumerateFiles(localPath, "*", SearchOption.AllDirectories).ToList();
            if (files.Count == 0)
            {
                log?.Invoke($"Warning: deployPaths: no files under {localPath}");
                continue;
            }
            foreach (var file in files)
            {
                var relFile = Path.GetRelativePath(localPath, file).Replace('\\', '/');
                outList.Add(new StageFileEntry(file, $"{destRel}/{relFile}"));
            }
        }
        return outList;
    }
}
