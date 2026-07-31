using Microsoft.UI.Xaml;

namespace Lumen.App;

public partial class App : Application
{
    private MainWindow? _window;

    public App()
    {
        try
        {
            InitializeComponent();
        }
        catch (Exception exception)
        {
            RecordUnhandledException(exception);
            throw;
        }
        UnhandledException += (_, eventArgs) =>
        {
            RecordUnhandledException(eventArgs.Exception);
            if (_window is null)
            {
                return;
            }
            eventArgs.Handled = true;
            _window.ShowFatalError(eventArgs.Exception.Message);
        };
    }

    private static void RecordUnhandledException(Exception exception)
    {
        try
        {
            var path = ErrorLogPath();
            var directory = Path.GetDirectoryName(path)!;
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, exception.ToString());
        }
        catch
        {
            // The original UI exception remains authoritative if diagnostics cannot be persisted.
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        ClearStaleErrorLog();
        _window = new MainWindow();
        _window.Activate();
    }

    private static void ClearStaleErrorLog()
    {
        try
        {
            File.Delete(ErrorLogPath());
        }
        catch
        {
            // A stale diagnostic must not prevent the management app from starting.
        }
    }

    private static string ErrorLogPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Lumen",
        "ui-error.log");
}
