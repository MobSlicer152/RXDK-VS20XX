using System.Numerics;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace Rxdk.Installer
{
    internal class BackgroundShader : ShaderEffect
    {
        private static readonly PixelShader pixelShader = new PixelShader
        {
            UriSource = new Uri("/Resources/BackgroundShader.ps", UriKind.Relative)
        };

        public BackgroundShader()
        {
            PixelShader = pixelShader;
            UpdateShaderValue(InputProperty);
            UpdateShaderValue(TimeProperty);
            UpdateShaderValue(AspectProperty);
        }

        public Brush Input
        {
            get => (Brush)GetValue(InputProperty);
            set => SetValue(InputProperty, value);
        }

        public static readonly DependencyProperty InputProperty =
            ShaderEffect.RegisterPixelShaderSamplerProperty(
                "Input",
                typeof(BackgroundShader),
                0);

        public double Time
        {
            get => (double)GetValue(TimeProperty);
            set => SetValue(TimeProperty, value);
        }

        public static readonly DependencyProperty TimeProperty =
            DependencyProperty.Register(
                "Time",
                typeof(double),
                typeof(BackgroundShader),
                new UIPropertyMetadata(
                    0.0,
                    PixelShaderConstantCallback(0)));

        public double Aspect
        {
            get => (double)GetValue(AspectProperty);
            set => SetValue(AspectProperty, value);
        }

        private static double GetAspect()
        {
            var window = Application.Current.MainWindow;
            return window.Width / window.Height;
        }

        public static readonly DependencyProperty AspectProperty =
            DependencyProperty.Register(
                "Aspect",
                typeof(double),
                typeof(BackgroundShader),
                new UIPropertyMetadata(GetAspect(),
                    PixelShaderConstantCallback(1)));
    }
}