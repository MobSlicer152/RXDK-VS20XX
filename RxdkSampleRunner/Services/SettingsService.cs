using System.IO;
using System.Text.Json;
using RxdkSampleRunner.Models;

namespace RxdkSampleRunner.Services;

/// <summary>Loads/saves <see cref="AppSettings"/> as JSON under %AppData%\RxdkSampleRunner.</summary>
public static class SettingsService
{
    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RxdkSampleRunner");
    private static readonly string File = Path.Combine(Dir, "settings.json");

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static AppSettings Load()
    {
        try
        {
            if (System.IO.File.Exists(File))
                return JsonSerializer.Deserialize<AppSettings>(System.IO.File.ReadAllText(File)) ?? new AppSettings();
        }
        catch { /* fall through to defaults on any parse/IO error */ }
        return new AppSettings();
    }

    public static void Save(AppSettings settings)
    {
        try
        {
            System.IO.Directory.CreateDirectory(Dir);
            System.IO.File.WriteAllText(File, JsonSerializer.Serialize(settings, Json));
        }
        catch { /* best-effort persistence */ }
    }
}
