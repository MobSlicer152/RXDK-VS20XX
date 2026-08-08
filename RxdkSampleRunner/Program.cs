using Avalonia;

namespace RxdkSampleRunner;

internal static class Program
{
    // Avalonia entry point. BuildAvaloniaApp() is separated so the visual designer can find it.
    [STAThread]
    public static void Main(string[] args) => BuildAvaloniaApp()
        .StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>()
        .UsePlatformDetect()
        .WithInterFont()
        .LogToTrace();
}
