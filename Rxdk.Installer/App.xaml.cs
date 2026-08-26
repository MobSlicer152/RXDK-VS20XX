using System.Configuration;
using System.Data;
using System.Windows;

namespace Rxdk.Installer
{
    /// <summary>
    /// Interaction logic for App.xaml
    /// </summary>
    public partial class App : Application
    {
        public App()
        {
            Thread.CurrentThread.Name = "Application thread";
        }

        public static App Get()
        {
            return (App)Application.Current;
        }

        public static MainWindow GetMainWindow()
        {
            return (MainWindow)Get().MainWindow;
        }

        public static void Log(string message)
        {
            Get().Dispatcher.Invoke(new Action(() =>
            {
                GetMainWindow().Log(message);
            }));
        }
    }

}
