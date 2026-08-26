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
        public MainWindow()
        {
            InitializeComponent();
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

        private void Window_GotFocus(object sender, RoutedEventArgs e)
        {
            Background.Fill = new SolidColorBrush(new Color() { R = 0, G = 0, B = 0, A = 1 });
        }

        private void Window_LostFocus(object sender, RoutedEventArgs e)
        {
            Background.Fill = Brushes.Black;
        }
    }
}