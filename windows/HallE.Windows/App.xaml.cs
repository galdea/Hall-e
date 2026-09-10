using System.IO;
using System.Text.Json;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace HallE.Windows;

public partial class App : Application
{
    private const string SingleInstanceMutexName = "Local\\Hall-e.Windows.0.1";
    private Mutex? _instanceMutex;
    private string? _smokeStorageRoot;
    private string? _smokeResultPath;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += OnDispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;

        if (!TryParseSmokeArguments(e.Args, out var smokeResultPath, out var smokeError))
        {
            MessageBox.Show(smokeError, "Hall-e startup error", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(64);
            return;
        }

        var smokeMode = smokeResultPath is not null;
        _smokeResultPath = smokeResultPath;
        if (!smokeMode)
        {
            _instanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var isFirstInstance);
            if (!isFirstInstance)
            {
                MessageBox.Show("Hall-e is already running for this Windows account.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
                _instanceMutex.Dispose();
                _instanceMutex = null;
                Shutdown(2);
                return;
            }
        }

        var storageRoot = smokeMode
            ? CreateSmokeStorageRoot()
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hall-e");

        try
        {
            var window = new MainWindow(storageRoot, smokeMode);
            MainWindow = window;
            if (smokeMode)
                window.Loaded += async (_, _) => await CompleteSmokeTestAsync(window, smokeResultPath!);
            window.Show();
        }
        catch (Exception ex)
        {
            if (smokeMode) WriteSmokeFailure(ex);
            else ShowFatalStartupError(ex);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instanceMutex?.ReleaseMutex();
        _instanceMutex?.Dispose();
        _instanceMutex = null;

        if (_smokeStorageRoot is not null)
        {
            try
            {
                if (Directory.Exists(_smokeStorageRoot))
                    Directory.Delete(_smokeStorageRoot, recursive: true);
            }
            catch
            {
                // Smoke storage lives in the OS temp directory and can be reclaimed later.
            }
        }

        AppDomain.CurrentDomain.UnhandledException -= OnUnhandledException;
        base.OnExit(e);
    }

    private static bool TryParseSmokeArguments(string[] args, out string? resultPath, out string error)
    {
        resultPath = null;
        error = string.Empty;

        if (args.Length == 0)
            return true;

        if (args.Length != 2 || !string.Equals(args[0], "--smoke-test", StringComparison.Ordinal))
        {
            error = "Supported startup syntax: Hall-e.exe or Hall-e.exe --smoke-test <result.json>.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(args[1]) || !string.Equals(Path.GetExtension(args[1]), ".json", StringComparison.OrdinalIgnoreCase))
        {
            error = "The smoke-test result path must name a .json file.";
            return false;
        }

        try
        {
            resultPath = Path.GetFullPath(args[1]);
            if (Directory.Exists(resultPath))
            {
                error = "The smoke-test result path points to a directory.";
                resultPath = null;
                return false;
            }
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            error = "The smoke-test result path is invalid.";
            return false;
        }

        return true;
    }

    private string CreateSmokeStorageRoot()
    {
        _smokeStorageRoot = Path.Combine(Path.GetTempPath(), "Hall-e-smoke", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_smokeStorageRoot);
        return _smokeStorageRoot;
    }

    private async Task CompleteSmokeTestAsync(MainWindow window, string resultPath)
    {
        try
        {
            await window.Initialization;
            await window.VerifySmokeMeetingRefreshAsync();
            // Yield once so the real WPF window reaches the dispatcher/render queue before success is recorded.
            await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);

            var directory = Path.GetDirectoryName(resultPath);
            if (string.IsNullOrWhiteSpace(directory))
                throw new InvalidOperationException("Smoke-test result path has no parent directory.");

            Directory.CreateDirectory(directory);
            window.UpdateLayout();
            var content = (FrameworkElement)window.Content;
            var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (var screenshot = File.Create(Path.ChangeExtension(resultPath, ".png"))) encoder.Save(screenshot);
            var temporaryPath = resultPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            var payload = JsonSerializer.Serialize(new
            {
                success = window.IsLoaded && window.Initialization.IsCompletedSuccessfully,
                windowLoaded = window.IsLoaded,
                meetingRefreshVerified = true,
                isolatedStorage = true,
                recordedAudio = false,
                cloudRequested = false
            }, new JsonSerializerOptions { WriteIndented = true });

            await File.WriteAllTextAsync(temporaryPath, payload);
            File.Move(temporaryPath, resultPath, overwrite: true);
            window.Close();
            Shutdown(0);
        }
        catch (Exception ex)
        {
            WriteSmokeFailure(ex);
            Shutdown(1);
        }
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        if (_smokeResultPath is not null)
        {
            WriteSmokeFailure(e.Exception);
            e.Handled = true;
            Shutdown(1);
            return;
        }
        MessageBox.Show($"Hall-e encountered an unexpected error:\n\n{e.Exception.Message}", "Hall-e error", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    private void WriteSmokeFailure(Exception exception)
    {
        if (_smokeResultPath is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(_smokeResultPath)!);
        File.WriteAllText(_smokeResultPath, JsonSerializer.Serialize(new { success = false, error = exception.ToString() }));
    }

    private static void OnUnhandledException(object? sender, UnhandledExceptionEventArgs e)
    {
        if (e.ExceptionObject is Exception ex)
            MessageBox.Show($"Hall-e encountered a fatal error:\n\n{ex.Message}", "Hall-e error", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    private static void ShowFatalStartupError(Exception ex) =>
        MessageBox.Show($"Hall-e could not start:\n\n{ex.Message}", "Hall-e startup error", MessageBoxButton.OK, MessageBoxImage.Error);
}
