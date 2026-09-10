using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
using HallE.Core;
using HallE.Windows.Services;
using HallE.Windows.UI;

namespace HallE.Windows;

public partial class SettingsWindow : Window
{
    private static readonly ProviderOption[] Providers =
    [
        new(TranscriptionProvider.Local, "Windows local"),
        new(TranscriptionProvider.Deepgram, "Deepgram"),
        new(TranscriptionProvider.Speechmatics, "Speechmatics")
    ];

    private static readonly RegionOption[] Regions =
    [
        new("eu", "Europe (EU)"),
        new("us", "United States (US)")
    ];

    private readonly LibraryStore _library;
    private readonly CredentialStore _credentials;
    private readonly TranscriptionService _transcriptionService;
    private AppSettings _settings = new();
    private bool _cloudOperationRunning;

    public SettingsWindow(LibraryStore library, CredentialStore credentials, TranscriptionService transcriptionService)
    {
        InitializeComponent();
        _library = library;
        _credentials = credentials;
        _transcriptionService = transcriptionService;
        ProviderComboBox.ItemsSource = Providers;
        SpeechmaticsRegionComboBox.ItemsSource = Regions;
    }

    private async void SettingsWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _settings = await Task.Run(_library.LoadSettings);
            ApplySettingsToControls(_settings);
            await LoadLocalLanguagesAsync();
            RefreshCredentialStatus();
        }
        catch (Exception ex)
        {
            ShowError("Could not load Hall-e settings", ex);
        }
    }

    private void ApplySettingsToControls(AppSettings settings)
    {
        ProviderComboBox.SelectedItem = Providers.First(p => p.Provider == settings.Provider);
        DeepgramConsentCheckBox.IsChecked = settings.DeepgramConsent;
        SpeechmaticsConsentCheckBox.IsChecked = settings.SpeechmaticsConsent;
        SpeechmaticsTrainingDisabledCheckBox.IsChecked = settings.SpeechmaticsTrainingDisabled;
        SpeechmaticsRegionComboBox.SelectedItem = Regions.FirstOrDefault(r => r.Id == settings.SpeechmaticsRegion) ?? Regions[0];
        LanguageComboBox.Text = settings.Language;
    }

    private async Task LoadLocalLanguagesAsync()
    {
        try
        {
            var installed = await Task.Run(_transcriptionService.GetLocalLanguages);
            var languages = new[] { _settings.Language, "en-US", "es-CL" }
                .Concat(installed)
                .Where(value => !string.IsNullOrWhiteSpace(value))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
                .ToArray();

            LanguageComboBox.ItemsSource = languages;
            LanguageComboBox.Text = _settings.Language;
            LocalModelsTextBlock.Text = installed.Count == 0
                ? "No compatible Windows SAPI speech model is installed. Local transcription remains unavailable until a Windows speech model is installed; Hall-e will not switch to cloud automatically."
                : string.Join(", ", installed);
            LocalModelsTextBlock.Foreground = (Brush)FindResource(installed.Count == 0 ? "WarningBrush" : "MutedTextBrush");
        }
        catch (Exception ex)
        {
            LocalModelsTextBlock.Text = $"Could not inspect installed Windows speech models: {ex.Message}";
            LocalModelsTextBlock.Foreground = (Brush)FindResource("DangerBrush");
        }
    }

    private async void SaveSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        if (_cloudOperationRunning)
            return;

        try
        {
            var updated = BuildSettingsFromControls();
            await Task.Run(() => _library.SaveSettings(updated));
            _settings = updated;
            DialogResult = true;
        }
        catch (Exception ex)
        {
            ShowError("Could not save settings", ex);
        }
    }

    private async void DeepgramSaveTestButton_Click(object sender, RoutedEventArgs e)
    {
        await ValidateAndSaveKeyAsync(TranscriptionProvider.Deepgram, DeepgramKeyPasswordBox.Password);
    }

    private async void SpeechmaticsSaveTestButton_Click(object sender, RoutedEventArgs e)
    {
        await ValidateAndSaveKeyAsync(TranscriptionProvider.Speechmatics, SpeechmaticsKeyPasswordBox.Password);
    }

    private async Task ValidateAndSaveKeyAsync(TranscriptionProvider provider, string key)
    {
        if (_cloudOperationRunning)
            return;

        if (string.IsNullOrWhiteSpace(key))
        {
            MessageBox.Show(this, $"Enter a {ProviderName(provider)} API key to validate and save.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        AppSettings pending;
        try
        {
            pending = BuildSettingsFromControls();
        }
        catch (Exception ex)
        {
            ShowError("Review the provider settings before saving the key", ex);
            return;
        }

        var keySaved = false;
        SetCloudOperationState(true, $"Testing {ProviderName(provider)} authentication…");
        try
        {
            await _transcriptionService.ValidateKeyAsync(provider, key.Trim(), pending.SpeechmaticsRegion);
            _credentials.SaveKey(provider, key.Trim());
            keySaved = true;
            await Task.Run(() => _library.SaveSettings(pending));
            _settings = pending;

            if (provider == TranscriptionProvider.Deepgram)
                DeepgramKeyPasswordBox.Clear();
            else
                SpeechmaticsKeyPasswordBox.Clear();

            RefreshCredentialStatus();
            SetStatus($"{ProviderName(provider)} key validated and saved securely. No meeting audio was uploaded for this test.");
        }
        catch (Exception ex)
        {
            ShowError(keySaved
                ? $"The {ProviderName(provider)} key was saved securely, but the settings could not be saved. Review the consent settings and try Save settings again"
                : $"The {ProviderName(provider)} key could not be validated or saved. Any previously saved key was preserved", ex);
        }
        finally
        {
            SetCloudOperationState(false, SettingsStatusTextBlock.Text);
        }
    }

    private async void DeepgramTestSavedButton_Click(object sender, RoutedEventArgs e)
    {
        await TestSavedKeyAsync(TranscriptionProvider.Deepgram);
    }

    private async void SpeechmaticsTestSavedButton_Click(object sender, RoutedEventArgs e)
    {
        await TestSavedKeyAsync(TranscriptionProvider.Speechmatics);
    }

    private async Task TestSavedKeyAsync(TranscriptionProvider provider)
    {
        if (_cloudOperationRunning)
            return;

        var region = SelectedRegion();
        SetCloudOperationState(true, $"Testing saved {ProviderName(provider)} key…");
        try
        {
            var key = _credentials.GetKey(provider);
            if (string.IsNullOrWhiteSpace(key))
                throw new InvalidOperationException($"No saved {ProviderName(provider)} key is available.");
            await _transcriptionService.ValidateKeyAsync(provider, key, region);
            SetStatus($"Saved {ProviderName(provider)} key is valid. The test did not upload meeting audio.");
        }
        catch (Exception ex)
        {
            ShowError($"Saved {ProviderName(provider)} key validation failed", ex);
        }
        finally
        {
            SetCloudOperationState(false, SettingsStatusTextBlock.Text);
        }
    }

    private void DeepgramRemoveButton_Click(object sender, RoutedEventArgs e) => RemoveKey(TranscriptionProvider.Deepgram);

    private void SpeechmaticsRemoveButton_Click(object sender, RoutedEventArgs e) => RemoveKey(TranscriptionProvider.Speechmatics);

    private void RemoveKey(TranscriptionProvider provider)
    {
        if (_cloudOperationRunning || !_credentials.HasKey(provider))
            return;

        var confirmation = MessageBox.Show(
            this,
            $"Remove the saved {ProviderName(provider)} API key from this Windows account?",
            "Remove cloud key",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);

        if (confirmation != MessageBoxResult.Yes)
            return;

        try
        {
            _credentials.DeleteKey(provider);
            RefreshCredentialStatus();
            SetStatus($"Saved {ProviderName(provider)} key removed.");
        }
        catch (Exception ex)
        {
            ShowError($"Could not remove the {ProviderName(provider)} key", ex);
        }
    }

    private AppSettings BuildSettingsFromControls()
    {
        var language = LanguageComboBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(language))
            throw new InvalidOperationException("Choose or enter a meeting language such as en-US or es-CL.");
        _ = System.Globalization.CultureInfo.GetCultureInfo(language);

        var provider = (ProviderComboBox.SelectedItem as ProviderOption)?.Provider ?? TranscriptionProvider.Local;
        var speechmaticsConsent = SpeechmaticsConsentCheckBox.IsChecked == true;
        var trainingDisabled = SpeechmaticsTrainingDisabledCheckBox.IsChecked == true;
        var region = SelectedRegion();

        if (speechmaticsConsent && !trainingDisabled)
            throw new InvalidOperationException("Speechmatics consent requires confirmation that training use is disabled.");

        if (provider == TranscriptionProvider.Speechmatics && !speechmaticsConsent)
            throw new InvalidOperationException("Enable Speechmatics audio-upload consent before making it the default provider.");

        if (provider == TranscriptionProvider.Deepgram && DeepgramConsentCheckBox.IsChecked != true)
            throw new InvalidOperationException("Enable Deepgram audio-upload consent before making it the default provider.");

        return _settings with
        {
            Language = language,
            Provider = provider,
            DeepgramConsent = DeepgramConsentCheckBox.IsChecked == true,
            SpeechmaticsConsent = speechmaticsConsent,
            SpeechmaticsRegion = region,
            SpeechmaticsTrainingDisabled = trainingDisabled
        };
    }

    private string SelectedRegion() =>
        (SpeechmaticsRegionComboBox.SelectedItem as RegionOption)?.Id ?? "eu";

    private void RefreshCredentialStatus()
    {
        var deepgramSaved = _credentials.HasKey(TranscriptionProvider.Deepgram);
        var speechmaticsSaved = _credentials.HasKey(TranscriptionProvider.Speechmatics);

        DeepgramStatusTextBlock.Text = deepgramSaved ? "Validated key is saved for this Windows user." : "No validated key saved.";
        SpeechmaticsStatusTextBlock.Text = speechmaticsSaved ? "Validated key is saved for this Windows user." : "No validated key saved.";
        DeepgramTestSavedButton.IsEnabled = deepgramSaved;
        DeepgramRemoveButton.IsEnabled = deepgramSaved;
        SpeechmaticsTestSavedButton.IsEnabled = speechmaticsSaved;
        SpeechmaticsRemoveButton.IsEnabled = speechmaticsSaved;
    }

    private void SetCloudOperationState(bool running, string message)
    {
        _cloudOperationRunning = running;
        DeepgramSaveTestButton.IsEnabled = !running;
        SpeechmaticsSaveTestButton.IsEnabled = !running;
        SaveSettingsButton.IsEnabled = !running;

        if (running)
        {
            DeepgramTestSavedButton.IsEnabled = false;
            DeepgramRemoveButton.IsEnabled = false;
            SpeechmaticsTestSavedButton.IsEnabled = false;
            SpeechmaticsRemoveButton.IsEnabled = false;
        }
        else
        {
            RefreshCredentialStatus();
        }

        SetStatus(message);
    }

    private void OpenMicrophoneSettingsButton_Click(object sender, RoutedEventArgs e) =>
        OpenFixedWindowsSettings("ms-settings:privacy-microphone", "Windows microphone privacy settings");

    private void OpenSoundSettingsButton_Click(object sender, RoutedEventArgs e) =>
        OpenFixedWindowsSettings("ms-settings:sound", "Windows sound settings");

    private void OpenFixedWindowsSettings(string fixedUri, string description)
    {
        try
        {
            Process.Start(new ProcessStartInfo(fixedUri) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            ShowError($"Could not open {description}", ex);
        }
    }

    private void SetStatus(string message, bool isError = false)
    {
        SettingsStatusTextBlock.Text = message;
        SettingsStatusTextBlock.Foreground = (Brush)FindResource(isError ? "DangerBrush" : "MutedTextBrush");
    }

    private void ShowError(string operation, Exception ex)
    {
        var message = string.IsNullOrWhiteSpace(ex.Message) ? ex.GetType().Name : ex.Message;
        SetStatus($"{operation}: {message}", isError: true);
        MessageBox.Show(this, $"{operation}.\n\n{message}", "Hall-e error", MessageBoxButton.OK, MessageBoxImage.Error);
    }

    private static string ProviderName(TranscriptionProvider provider) => provider switch
    {
        TranscriptionProvider.Deepgram => "Deepgram",
        TranscriptionProvider.Speechmatics => "Speechmatics",
        _ => "Windows local speech"
    };

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (_cloudOperationRunning)
        {
            e.Cancel = true;
            SetStatus("The connection test is still running. Close settings after it finishes.");
        }
        base.OnClosing(e);
    }
}
