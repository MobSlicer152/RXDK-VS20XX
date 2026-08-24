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
    }
}