using System.IO;
using System.Numerics;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Navigation;
using System.Windows.Shapes;

namespace Rxdk.Installer
{
    /// <summary>
    /// Interaction logic for MainWindow.xaml
    /// </summary>
    public partial class MainWindow : Window
    {
        Installer? installer;
        Thread? installThread;

        public MainWindow()
        {
            InitializeComponent();
            var path = Environment.GetEnvironmentVariable(Installer.InstallRootVariable);
            if (path != null)
            {
                InstallPath.Text = path;
                if (Directory.Exists(path))
                {
                    Install.Content = "Reinstall";
                }
            }
        }

        private void Minimize_Click(object sender, RoutedEventArgs e)
        {
            WindowState = WindowState.Minimized;
        }

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        private bool dragging = false;
        private Point dragStart = new Point(0, 0);

        private void Window_StartDrag(object sender, MouseButtonEventArgs e)
        {
            dragging = true;
            dragStart = Mouse.GetPosition(null);
        }

        private void Window_Drag(object sender, MouseEventArgs e)
        {
            if (dragging)
            {
                CaptureMouse();
                var pos = Mouse.GetPosition(null);
                var delta = pos - dragStart;
                Left += delta.X;
                Top += delta.Y;
            }
        }

        private void Window_ReleaseDrag(object sender, MouseButtonEventArgs e)
        {
            dragging = false;
            ReleaseMouseCapture();
        }

        private void Window_Activated(object sender, EventArgs e)
        {
            ((Window)this).Background = new SolidColorBrush(new Color() { R = 0, G = 0, B = 0, A = 1 });
        }

        private void Window_Deactivated(object sender, EventArgs e)
        {
            ((Window)this).Background = Brushes.Black;
        }

        public void Log(string message)
        {
            Console.WriteLine(message);
            InstallLog.Text += $"{message}\n";
            InstallLog.LineDown();
        }

        private void Install_Click(object sender, RoutedEventArgs e)
        {
            // stop multiple installations
            if (installer != null || installThread != null)
            {
                return;
            }

            Log(Directory.Exists(InstallPath.Text) ? "Reinstalling" : "Installing");

            // disable any buttons
            InstallPath.IsEnabled = false;
            InstallBrowse.IsEnabled = false;
            StartMenuFolder.IsEnabled = false;
            CreateStartMenuFolder.IsEnabled = false;
            InstallVsExtension.IsEnabled = false;
            InstallDocs.IsEnabled = false;
            InstallSamples.IsEnabled = false;
            Install.IsEnabled = false;

            // set up the installer
            installer = new Installer()
            {
                InstallPath = InstallPath.Text,
                StartMenuFolder = StartMenuFolder.Text,
                CreateStartMenuFolder = CreateStartMenuFolder.IsChecked ?? true,
                InstallVsExtension = InstallVsExtension.IsChecked ?? true,
                InstallDocs = InstallDocs.IsChecked ?? true,
                InstallSamples = InstallSamples.IsChecked ?? true,
            };

            // clean up when the install is completed
            installer.InstallCompleted += (bool incomplete) =>
            {
                Dispatcher.Invoke(new Action(() =>
                {
                    Cancel.IsEnabled = false;
                    if (!incomplete)
                    {
                        Log("Installation complete");
                    }
                    installer = null;
                    installThread = null;
                }));
            };

            installer.Progress += (float progress, string text) =>
            {
                Dispatcher.Invoke(new Action(() =>
                {
                    ProgressText.Content = $"{progress * 100:.2f}% - {text}";
                    TotalProgress.Value = progress * 100;
                }));
            };

            // run the installation on another thread
            installThread = new Thread(() => { installer.Install(); });
            installThread.Name = "Install thread";
            installThread.Start();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            if (installer == null || installThread == null || installer.Cancelled)
            {
                return;
            }

            Log("Cancelled");
            Cancel.IsEnabled = false;
            installer.Cancel();
            installThread.Join();
        }
    }
}
