using Avalonia.Controls;
using Avalonia.Markup.Xaml;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using RxdkSampleRunner.ViewModels;

namespace RxdkSampleRunner.Views;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object? sender, EventArgs e)
    {
        if (DataContext is not MainViewModel vm) return;

        vm.BrowseExeAsync = PickExeAsync;
        vm.BrowseFolderAsync = PickFolderAsync;

        // Auto-scroll the console to the newest output whenever the log changes.
        vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(MainViewModel.Log))
                Dispatcher.UIThread.Post(() => this.FindControl<ScrollViewer>("LogScroll")?.ScrollToEnd());
        };
    }

    private async void CopyLog_Click(object? sender, Avalonia.Interactivity.RoutedEventArgs e)
    {
        if (DataContext is not MainViewModel vm) return;
        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is not null)
            await clipboard.SetTextAsync(vm.Log ?? "");
    }

    private async Task<string?> PickExeAsync()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Select the xemu executable",
            AllowMultiple = false,
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    private async Task<string?> PickFolderAsync()
    {
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "Select the samples root folder",
            AllowMultiple = false,
        });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }
}
