using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Lumen.App;

internal static class AppStrings
{
    // The unpackaged WinUI application publishes a view-independent
    // `Resources` map into Lumen.pri. The parameterless Windows App SDK
    // loader resolves against a packaged app identity and fails at runtime
    // with 0x80073B17 (NamedResource Not Found).
    private static readonly ResourceLoader Loader = ResourceLoader.GetForViewIndependentUse();

    internal static string Get(string key) => Loader.GetString(key);

    internal static string Format(string key, params object[] values) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), values);
}
