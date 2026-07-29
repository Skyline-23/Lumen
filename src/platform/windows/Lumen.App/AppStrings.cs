using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Lumen.App;

internal static class AppStrings
{
    private static readonly ResourceLoader Loader = new();

    internal static string Get(string key) => Loader.GetString(key);

    internal static string Format(string key, params object[] values) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), values);
}
