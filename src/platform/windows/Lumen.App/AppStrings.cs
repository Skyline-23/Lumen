using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;

namespace Lumen.App;

internal static class AppStrings
{
    // Load the unpackaged app's PRI explicitly. ResourceLoader's parameterless
    // constructor resolves against package identity, while this app ships as
    // an unpackaged self-contained executable.
    private static readonly ResourceManager Manager = new(
        Path.Combine(AppContext.BaseDirectory, "Lumen.pri"));
    private static readonly ResourceMap Resources = Manager.MainResourceMap.GetSubtree("Resources");
    private static readonly ResourceContext Context = Manager.CreateResourceContext();

    internal static string Get(string key)
    {
        // MRT stores dotted RESW names as URI-path segments (for example,
        // `Authentication.HeroTitle` becomes `Authentication/HeroTitle`).
        // ResourceLoader performed that conversion for packaged apps, so do it
        // explicitly when resolving this unpackaged PRI map.
        var candidate = Resources.TryGetValue(key, Context) ??
                        Resources.TryGetValue(key.Replace('.', '/'), Context);
        return candidate?.ValueAsString ?? throw new InvalidOperationException(
            $"The localized resource '{key}' is missing from Lumen.pri.");
    }

    internal static string Format(string key, params object[] values) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), values);
}
