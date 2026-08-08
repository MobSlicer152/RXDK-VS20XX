using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace RxdkSampleRunner.ViewModels;

/// <summary>bool -> brush: true = green (ISO ready), false = gray (not built).</summary>
public sealed class BoolBrush : IValueConverter
{
    public static readonly BoolBrush GreenGray = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        (value is bool b && b) ? Brushes.LightGreen : Brushes.Gray;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
