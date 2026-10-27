using ActionRecorder.Core;
using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace ActionRecorder.Desktop;

/// <summary>True becomes Collapsed and false becomes Visible.</summary>
public sealed class InverseBoolToVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>A non-empty string or non-zero number becomes Visible.</summary>
public sealed class HasValueToVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value switch
        {
            null => Visibility.Collapsed,
            string s => s.Length > 0 ? Visibility.Visible : Visibility.Collapsed,
            int i => i != 0 ? Visibility.Visible : Visibility.Collapsed,
            bool b => b ? Visibility.Visible : Visibility.Collapsed,
            _ => Visibility.Visible,
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Zero or empty becomes Visible (used for "nothing here yet" messages).</summary>
public sealed class EmptyToVisibility : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value switch
        {
            null => Visibility.Visible,
            string s => s.Length == 0 ? Visibility.Visible : Visibility.Collapsed,
            int i => i == 0 ? Visibility.Visible : Visibility.Collapsed,
            bool b => b ? Visibility.Collapsed : Visibility.Visible,
            _ => Visibility.Collapsed,
        };

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

/// <summary>Turns 0..1 into a width in pixels, for the hand-drawn progress bars. The parameter is the full width.</summary>
public sealed class FractionToWidth : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var fraction = value is double d ? Math.Clamp(d, 0, 1) : 0;
        var full = parameter is string s && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var w) ? w : 100;
        return fraction * full;
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}

public sealed class InverseBool : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => value is not true;
}

/// <summary>Null becomes true, anything else false (used for an indeterminate progress bar while the size is unknown).</summary>
public sealed class NullToTrue : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value == null;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
