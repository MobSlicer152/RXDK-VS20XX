using Rxdk.Engine.Platform;

namespace Rxdk.Engine.Bootstrap;

/// <summary>
/// Clones/updates the RXDK-Samples repo (the ported XDK sample suite + the sample runner) into
/// the staged samples root (…/RXDK/samples). Mirrors <see cref="SdkStaging"/>/<see cref="DocsStaging"/>:
/// pull if it's a git checkout, else clone, never overwriting a non-git folder. The RXDK tool
/// window's "Download RXDK Samples" / "Open Samples Folder" commands read from this same root.
/// Samples are optional — they are not part of the build prerequisites, only downloaded on request.
/// </summary>
public static class SamplesStaging
{
    public const string DefaultSamplesGitUrl = "https://github.com/Team-Resurgent/RXDK-Samples.git";

    /// <summary>Samples clone URL, honoring the RXDK_SAMPLES_GIT_URL override.</summary>
    public static string GetSamplesGitUrl()
    {
        var env = Environment.GetEnvironmentVariable("RXDK_SAMPLES_GIT_URL");
        return !string.IsNullOrWhiteSpace(env) ? env.Trim() : DefaultSamplesGitUrl;
    }

    /// <summary>Optional branch/tag to clone, from RXDK_SAMPLES_GIT_REF (null = default branch).</summary>
    public static string? GetSamplesGitRef()
    {
        var env = Environment.GetEnvironmentVariable("RXDK_SAMPLES_GIT_REF");
        return string.IsNullOrWhiteSpace(env) ? null : env.Trim();
    }

    /// <summary>Samples present (the RxdkSamples/ project tree exists under the staged root).</summary>
    public static bool IsStagedSamplesPresent() =>
        Directory.Exists(Path.Combine(RxdkPaths.GetStagedSamplesRoot(), "RxdkSamples"));

    private static bool IsGitRepo(string dir) => Directory.Exists(Path.Combine(dir, ".git"));

    /// <summary>
    /// Ensure the staged samples are present and up to date: pull if it's a git checkout, else
    /// clone. Never silently overwrites a non-git folder. Returns the staged root.
    /// </summary>
    public static async Task<string> EnsureAsync(
        Action<string>? log = null, CancellationToken ct = default)
    {
        var staged = RxdkPaths.GetStagedSamplesRoot();
        var url = GetSamplesGitUrl();
        var gitRef = GetSamplesGitRef();

        if (IsGitRepo(staged))
        {
            var branch = gitRef ?? await CurrentBranchAsync(staged, ct) ?? "main";
            log?.Invoke($"RXDK: fetching latest RXDK-Samples ({branch}) → {staged}");
            await Git(new[] { "fetch", "--progress", "--depth", "1", "origin", branch },
                cwd: staged, log: log, ct: ct);
            await Git(new[] { "-C", staged, "reset", "--hard", $"origin/{branch}" }, log: log, ct: ct);
            log?.Invoke($"RXDK: samples updated at {staged}");
            return staged;
        }

        if (Directory.Exists(staged) && Directory.EnumerateFileSystemEntries(staged).Any())
            throw new InvalidOperationException(
                $"Samples folder exists but is not a git checkout — refusing to overwrite: {staged}. " +
                "Delete it to re-clone.");

        log?.Invoke($"RXDK: cloning {url}{(gitRef is null ? "" : $" ({gitRef})")} → {staged}");
        Directory.CreateDirectory(Path.GetDirectoryName(staged)!);
        var args = new List<string> { "clone", "--progress", "--depth", "1" };
        if (gitRef is not null) { args.Add("--branch"); args.Add(gitRef); }
        args.Add(url);
        args.Add(staged);
        await Git(args, log: log, ct: ct);

        if (!IsStagedSamplesPresent())
            throw new InvalidOperationException(
                $"Samples clone completed but RxdkSamples/ is missing under {staged}.");
        log?.Invoke($"RXDK: samples cloned to {staged}");
        return staged;
    }

    private static async Task<string?> CurrentBranchAsync(string repoDir, CancellationToken ct)
    {
        var r = await ProcessRunner.RunAsync(
            "git", new[] { "-C", repoDir, "rev-parse", "--abbrev-ref", "HEAD" }, ct: ct);
        var branch = r.StdOut.Trim();
        return r.Success && branch.Length > 0 && branch != "HEAD" ? branch : null;
    }

    private static async Task Git(
        IEnumerable<string> args, string? cwd = null, Action<string>? log = null,
        CancellationToken ct = default)
    {
        var r = await ProcessRunner.RunAsync(
            "git", args, workingDirectory: cwd,
            onStdErrLine: line =>
            {
                if (line.Contains("Receiving objects:", StringComparison.Ordinal))
                    log?.Invoke($"  {line.Trim()}");
            },
            ct: ct);
        if (!r.Success)
            throw new InvalidOperationException(
                $"git failed ({r.ExitCode}): {r.StdErr.Trim()}".Trim());
    }
}
