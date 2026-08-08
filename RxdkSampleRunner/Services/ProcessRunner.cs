using System.Diagnostics;

namespace RxdkSampleRunner.Services;

/// <summary>
/// Runs an external process, streaming stdout+stderr lines to a callback as they arrive.
/// Used for msbuild, the rxdk CLI, and xemu — the last of which streams the title's serial
/// console output (via "-serial stdio") for the duration of the emulator session.
/// </summary>
public static class ProcessRunner
{
    public static async Task<int> RunAsync(
        string exe,
        IEnumerable<string> args,
        string? workingDirectory,
        Action<string> onLine,
        CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            WorkingDirectory = workingDirectory ?? "",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        onLine($"$ {exe} {string.Join(' ', psi.ArgumentList.Select(Quote))}");

        using var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        proc.OutputDataReceived += (_, e) => { if (e.Data is not null) onLine(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data is not null) onLine(e.Data); };

        try
        {
            proc.Start();
        }
        catch (Exception ex)
        {
            onLine($"ERROR: cannot start '{exe}': {ex.Message}");
            return -1;
        }

        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        using (ct.Register(() => { try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch { } }))
        {
            await proc.WaitForExitAsync(ct).ConfigureAwait(false);
        }
        return proc.ExitCode;
    }

    private static string Quote(string a) => a.Contains(' ') ? $"\"{a}\"" : a;
}
