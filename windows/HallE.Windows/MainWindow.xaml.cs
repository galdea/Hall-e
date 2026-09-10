using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using HallE.Core;
using HallE.Windows.Services;
using HallE.Windows.UI;
using Microsoft.Win32;

namespace HallE.Windows;

public partial class MainWindow : Window
{
    private static readonly ProviderOption[] ProviderOptions =
    [
        new(TranscriptionProvider.Local, "Windows local"),
        new(TranscriptionProvider.Deepgram, "Deepgram"),
        new(TranscriptionProvider.Speechmatics, "Speechmatics")
    ];

    private readonly LibraryStore _library;
    private readonly CredentialStore _credentials;
    private readonly TranscriptionService _transcriptionService;
    private readonly AudioRecorder _recorder;
    private readonly bool _smokeMode;
    private readonly Stopwatch _recordingStopwatch = new();
    private readonly DispatcherTimer _recordingTimer;
    private readonly DispatcherTimer _notesAutosaveTimer;
    private readonly DispatcherTimer _searchTimer;
    private readonly DispatcherTimer _playbackTimer;
    private readonly MediaPlayer _mediaPlayer = new();

    private List<ProjectRecord> _projects = [];
    private MeetingRecord? _selectedMeeting;
    private MeetingRecord? _recordingMeeting;
    private CancellationTokenSource? _transcriptionCts;
    private Task? _transcriptionTask;
    private bool _loadingMeeting;
    private bool _notesDirty;
    private bool _suppressMeetingSelection;
    private bool _microphonesAvailable;
    private bool _playbackStarted;
    private string? _playbackMeetingId;
    private bool _closeInProgress;
    private bool _allowClose;
    private bool _resourcesDisposed;
    private int _meetingLoadVersion;
    private int _libraryRefreshVersion;
    private bool _recordingStarting;
    private bool _transcriptionStarting;
    private Task? _stopRecordingTask;
    private readonly TaskCompletionSource _initialization = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task Initialization => _initialization.Task;

    public MainWindow(string storageRoot, bool smokeMode = false)
    {
        InitializeComponent();

        _smokeMode = smokeMode;
        _library = new LibraryStore(storageRoot);
        _credentials = new CredentialStore(storageRoot);
        _transcriptionService = new TranscriptionService(_library, _credentials);
        _recorder = new AudioRecorder();

        _recordingTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _recordingTimer.Tick += RecordingTimer_Tick;

        _notesAutosaveTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _notesAutosaveTimer.Tick += NotesAutosaveTimer_Tick;

        _searchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _searchTimer.Tick += SearchTimer_Tick;

        _playbackTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _playbackTimer.Tick += PlaybackTimer_Tick;

        _recorder.LevelChanged += Recorder_LevelChanged;
        _recorder.Warning += Recorder_Warning;
        _mediaPlayer.MediaOpened += MediaPlayer_MediaOpened;
        _mediaPlayer.MediaEnded += MediaPlayer_MediaEnded;
        _mediaPlayer.MediaFailed += MediaPlayer_MediaFailed;

        TranscriptionProviderComboBox.ItemsSource = ProviderOptions;
        TranscriptionProviderComboBox.SelectedIndex = 0;
    }

    private async void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            var settings = await Task.Run(_library.LoadSettings);
            SetSelectedProvider(settings.Provider);
            var recoveryFailures = _smokeMode ? 0 : await Task.Run(() => RecordingRecoveryService.RecoverInterruptedMeetings(_library));
            await RefreshProjectsAsync();

            if (_smokeMode)
            {
                MicrophoneComboBox.ItemsSource = new[] { new AudioDevice("smoke", "Microphone check skipped in smoke test") };
                MicrophoneComboBox.SelectedIndex = 0;
                _microphonesAvailable = false;
                StartRecordingButton.IsEnabled = false;
                OnboardingOverlay.Visibility = Visibility.Collapsed;
            }
            else
            {
                await LoadMicrophonesAsync();
                OnboardingOverlay.Visibility = settings.OnboardingCompleted ? Visibility.Collapsed : Visibility.Visible;
            }

            await RefreshMeetingsAsync();
            _notesAutosaveTimer.Start();
            ShowStatus(recoveryFailures > 0
                ? $"Ready. {recoveryFailures} interrupted recording(s) need attention; their original files were preserved."
                : _smokeMode ? "Smoke-test window loaded with isolated local storage." : "Ready. Nothing records until you start a recording.",
                isError: recoveryFailures > 0);
            _initialization.TrySetResult();
        }
        catch (Exception ex)
        {
            _initialization.TrySetException(ex);
            if (!_smokeMode) ShowError("Hall-e could not finish loading", ex);
        }
    }

    private async Task LoadMicrophonesAsync()
    {
        ShowStatus("Checking microphones…");
        var microphones = await Task.Run(() => _recorder.GetMicrophones());
        MicrophoneComboBox.ItemsSource = microphones;
        _microphonesAvailable = microphones.Count > 0;

        if (_microphonesAvailable)
        {
            MicrophoneComboBox.SelectedIndex = 0;
            StartRecordingButton.IsEnabled = true;
            ShowStatus($"Ready · {microphones.Count} microphone{(microphones.Count == 1 ? "" : "s")} available.");
        }
        else
        {
            MicrophoneComboBox.ItemsSource = new[] { new AudioDevice("", "No microphone found") };
            MicrophoneComboBox.SelectedIndex = 0;
            StartRecordingButton.IsEnabled = false;
            ShowStatus("No microphone is available. Check Windows microphone privacy and sound settings.", isError: true);
        }
    }

    private async Task RefreshProjectsAsync(string? selectRecordProjectId = null)
    {
        var previousRecordId = selectRecordProjectId ?? (RecordProjectComboBox.SelectedItem as ProjectOption)?.Id;
        var previousSelectedId = (SelectedProjectComboBox.SelectedItem as ProjectOption)?.Id ?? _selectedMeeting?.ProjectId;
        var previousFilter = ProjectFilterComboBox.SelectedItem as ProjectOption;

        _projects = (await Task.Run(_library.ListProjects)).ToList();

        var assignmentOptions = new List<ProjectOption> { new(null, "No project") };
        assignmentOptions.AddRange(_projects.Select(p => new ProjectOption(p.Id, p.Name)));
        RecordProjectComboBox.ItemsSource = assignmentOptions;
        SelectedProjectComboBox.ItemsSource = assignmentOptions.ToArray();

        var filterOptions = new List<ProjectOption>
        {
            new(null, "All projects", IsAll: true),
            new(null, "No project")
        };
        filterOptions.AddRange(_projects.Select(p => new ProjectOption(p.Id, p.Name)));
        ProjectFilterComboBox.ItemsSource = filterOptions;

        SelectProjectOption(RecordProjectComboBox, previousRecordId, preferAll: false);
        SelectProjectOption(SelectedProjectComboBox, previousSelectedId, preferAll: false);

        if (previousFilter is null)
            ProjectFilterComboBox.SelectedIndex = 0;
        else if (previousFilter.IsAll)
            ProjectFilterComboBox.SelectedIndex = 0;
        else
            SelectProjectOption(ProjectFilterComboBox, previousFilter.Id, preferAll: false);
    }

    private async Task RefreshMeetingsAsync(string? selectMeetingId = null)
    {
        var refreshVersion = ++_libraryRefreshVersion;
        var query = SearchTextBox.Text.Trim();
        var filter = ProjectFilterComboBox.SelectedItem as ProjectOption;
        var desiredId = selectMeetingId ?? _selectedMeeting?.Id;
        var projectsById = _projects.ToDictionary(p => p.Id, p => p.Name, StringComparer.Ordinal);

        var meetings = await Task.Run(() => _library.ListMeetings(string.IsNullOrWhiteSpace(query) ? null : query));
        if (refreshVersion != _libraryRefreshVersion)
            return;

        IEnumerable<MeetingRecord> filtered = meetings;
        if (filter is { IsAll: false })
            filtered = filter.Id is null
                ? filtered.Where(m => m.ProjectId is null)
                : filtered.Where(m => m.ProjectId == filter.Id);

        var items = filtered
            .Select(m => new MeetingListItem(m, m.ProjectId is not null && projectsById.TryGetValue(m.ProjectId, out var projectName) ? projectName : "No project"))
            .ToArray();

        _suppressMeetingSelection = true;
        MeetingsListBox.ItemsSource = items;
        var desiredItem = desiredId is null ? null : items.FirstOrDefault(i => i.Meeting.Id == desiredId);
        MeetingsListBox.SelectedItem = desiredItem;
        _suppressMeetingSelection = false;

        if (selectMeetingId is not null && desiredItem is not null)
        {
            await SwitchMeetingAsync(desiredItem.Meeting, reload: true);
        }
        else if (_selectedMeeting is not null && desiredItem is null)
        {
            if (!TrySaveCurrentNotes())
                return;
            StopPlayback();
            ClearMeetingDetail();
        }
    }

    private async Task SwitchMeetingAsync(MeetingRecord? requestedMeeting, bool reload = false)
    {
        // Every selection supersedes older loads, including a return to the
        // already displayed meeting while another selection is still loading.
        var loadVersion = ++_meetingLoadVersion;
        if (!reload && requestedMeeting?.Id == _selectedMeeting?.Id && _selectedMeeting is not null)
            return;

        if (!TrySaveCurrentNotes())
        {
            RestoreMeetingSelection();
            return;
        }

        StopPlayback();

        if (requestedMeeting is null)
        {
            ClearMeetingDetail();
            return;
        }

        try
        {
            var data = await Task.Run(() =>
            {
                var fresh = _library.GetMeeting(requestedMeeting.Id);
                return (Meeting: fresh, Notes: _library.GetNotes(fresh.Id), Transcript: _library.GetTranscript(fresh.Id));
            });

            if (loadVersion != _meetingLoadVersion)
                return;

            if (!TrySaveCurrentNotes())
            {
                RestoreMeetingSelection();
                return;
            }

            // Notes may have changed while metadata was loading. Use the draft
            // just saved above when refreshing the currently selected meeting.
            var notes = _selectedMeeting?.Id == data.Meeting.Id ? NotesTextBox.Text : data.Notes;
            _selectedMeeting = data.Meeting;
            _loadingMeeting = true;
            SelectedTitleTextBox.Text = data.Meeting.Title;
            SelectProjectOption(SelectedProjectComboBox, data.Meeting.ProjectId, preferAll: false);
            NotesTextBox.Text = notes;
            TranscriptTextBox.Text = data.Transcript;
            _notesDirty = false;
            NotesAutosaveTextBlock.Text = "Notes autosave locally";
            _loadingMeeting = false;

            UpdateMeetingDetailState(data.Meeting);
        }
        catch (Exception ex)
        {
            if (loadVersion != _meetingLoadVersion) return;
            _loadingMeeting = false;
            ShowError("Could not open this meeting", ex);
        }
    }

    private void UpdateMeetingDetailState(MeetingRecord meeting)
    {
        MeetingDetailBorder.IsEnabled = true;
        SelectedMeetingDateTextBlock.Text = $"{meeting.DisplayDate} · {meeting.DisplayDuration} · {meeting.Language}";
        SelectedMeetingStatusTextBlock.Text = FriendlyStatus(meeting.Status);

        var audioExists = File.Exists(_library.GetAudioPath(meeting.Id));
        var busy = meeting.Status is "recording" or "transcribing";
        PlayPauseButton.IsEnabled = audioExists && !busy;
        DeleteAudioButton.IsEnabled = audioExists && !busy;
        TranscribeButton.IsEnabled = audioExists && !busy && _transcriptionTask is null && _recordingMeeting is null;

        if (!audioExists)
        {
            PlayPauseButton.Content = "No audio";
            PlaybackProgressBar.Value = 0;
            PlaybackTimeTextBlock.Text = "00:00 / 00:00";
        }
        else
        {
            PlayPauseButton.Content = "Play audio";
        }

        if (!string.IsNullOrWhiteSpace(meeting.TranscriptionError))
        {
            TranscriptionErrorTextBlock.Text = meeting.TranscriptionError;
            TranscriptionErrorTextBlock.Visibility = Visibility.Visible;
        }
        else
        {
            TranscriptionErrorTextBlock.Text = string.Empty;
            TranscriptionErrorTextBlock.Visibility = Visibility.Collapsed;
        }
    }

    private void ClearMeetingDetail()
    {
        ++_meetingLoadVersion;
        _selectedMeeting = null;
        _loadingMeeting = true;
        SelectedTitleTextBox.Text = string.Empty;
        NotesTextBox.Text = string.Empty;
        TranscriptTextBox.Text = string.Empty;
        _loadingMeeting = false;
        _notesDirty = false;
        SelectedMeetingDateTextBlock.Text = "Choose a meeting from the library";
        SelectedMeetingStatusTextBlock.Text = string.Empty;
        TranscriptionErrorTextBlock.Visibility = Visibility.Collapsed;
        MeetingDetailBorder.IsEnabled = false;
    }

    private async void MeetingsListBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressMeetingSelection)
            return;

        var item = MeetingsListBox.SelectedItem as MeetingListItem;
        await SwitchMeetingAsync(item?.Meeting);
    }

    private void SearchTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!IsLoaded)
            return;
        _searchTimer.Stop();
        _searchTimer.Start();
    }

    private async void SearchTimer_Tick(object? sender, EventArgs e)
    {
        _searchTimer.Stop();
        try
        {
            await RefreshMeetingsAsync();
        }
        catch (Exception ex)
        {
            ShowError("Library search failed", ex);
        }
    }

    private async void ProjectFilterComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded)
            return;
        try
        {
            await RefreshMeetingsAsync();
        }
        catch (Exception ex)
        {
            ShowError("Could not filter the library", ex);
        }
    }

    private async void NewProjectButton_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ProjectNameDialog(this);
        if (dialog.ShowDialog() != true)
            return;

        try
        {
            var project = await Task.Run(() => _library.CreateProject(dialog.ProjectName));
            await RefreshProjectsAsync(project.Id);
            await RefreshMeetingsAsync();
            ShowStatus($"Project “{project.Name}” is ready.");
        }
        catch (Exception ex)
        {
            ShowError("Could not create the project", ex);
        }
    }

    private void SystemAudioRadio_Checked(object sender, RoutedEventArgs e) =>
        SystemAudioWarningBorder.Visibility = Visibility.Visible;

    private void SystemAudioRadio_Unchecked(object sender, RoutedEventArgs e) =>
        SystemAudioWarningBorder.Visibility = Visibility.Collapsed;

    private async void StartRecordingButton_Click(object sender, RoutedEventArgs e)
    {
        if (_smokeMode || _recordingStarting || _transcriptionStarting)
            return;

        if (_recordingMeeting is not null || _recorder.HasActiveSession)
        {
            MessageBox.Show(this, "A recording is already active. Stop it before starting another.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        if (_transcriptionTask is { IsCompleted: false })
        {
            MessageBox.Show(this, "Wait for the current transcription to finish or cancel it before recording.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        if (!_microphonesAvailable || MicrophoneComboBox.SelectedItem is not AudioDevice microphone || string.IsNullOrWhiteSpace(microphone.Id))
        {
            MessageBox.Show(this, "Choose an available microphone before recording.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var captureMode = SystemAudioRadio.IsChecked == true ? CaptureMode.MicrophoneAndSystem : CaptureMode.Microphone;
        if (captureMode == CaptureMode.MicrophoneAndSystem)
        {
            var confirmation = MessageBox.Show(
                this,
                "For this recording, Hall-e will capture your microphone and all audio playing on this computer. This can include other apps, calls, notifications, music, and system sounds.\n\nContinue with all-computer-audio capture?",
                "Confirm all-computer-audio capture",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (confirmation != MessageBoxResult.Yes)
                return;
        }

        MeetingRecord? meeting = null;
        _recordingStarting = true;
        try
        {
            SetRecordingComposerEnabled(false);
            RecordingStateTextBlock.Text = "Starting…";
            ShowStatus("Starting recording…");

            var settings = await Task.Run(_library.LoadSettings);
            var projectId = (RecordProjectComboBox.SelectedItem as ProjectOption)?.Id;
            var title = RecordTitleTextBox.Text;

            meeting = await Task.Run(() => _library.CreateMeeting(title, projectId, settings.Language, captureMode));
            var recordingMetadata = meeting with { Status = "recording" };
            await Task.Run(() => _library.SaveMeeting(recordingMetadata));
            meeting = recordingMetadata;

            await _recorder.StartAsync(_library.GetAudioPath(meeting.Id), captureMode, microphone.Id);

            _recordingMeeting = meeting;
            _recordingStopwatch.Restart();
            _recordingTimer.Start();
            RecordingStateTextBlock.Text = captureMode == CaptureMode.MicrophoneAndSystem ? "Recording microphone + computer audio" : "Recording microphone";
            StopRecordingButton.IsEnabled = true;
            StartRecordingButton.IsEnabled = false;
            SettingsButton.IsEnabled = false;
            ShowStatus("Recording. Use Stop to finish and safely close the audio file.");

            await RefreshMeetingsAsync(meeting.Id);
            RecordTitleTextBox.Text = string.Empty;
        }
        catch (Exception ex)
        {
            if (meeting is not null && !_recorder.HasActiveSession)
            {
                try
                {
                    await Task.Run(() => _library.UpdateMeeting(meeting.Id, fresh => fresh with { Status = "recording-error" }));
                    await RefreshMeetingsAsync(meeting.Id);
                }
                catch (Exception metadataError)
                {
                    ShowError("Recording failed and Hall-e could not update its local status", metadataError);
                }
            }

            if (_recorder.HasActiveSession && meeting is not null)
            {
                _recordingMeeting = meeting;
                _recordingStopwatch.Restart();
                _recordingTimer.Start();
                StopRecordingButton.IsEnabled = true;
                RecordingStateTextBlock.Text = "Capture may still be active — press Stop";
            }
            else
            {
                SetRecordingComposerEnabled(true);
            }

            ShowError("Recording could not start", ex);
        }
        finally { _recordingStarting = false; }
    }

    private async void StopRecordingButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await StopRecordingAsync();
        }
        catch (Exception ex)
        {
            ShowError("Hall-e could not stop the recording cleanly. The window will stay open so you can retry Stop", ex);
        }
    }

    private async Task StopRecordingAsync()
    {
        _stopRecordingTask ??= StopRecordingCoreAsync();
        try { await _stopRecordingTask; }
        finally { _stopRecordingTask = null; }
    }

    private async Task StopRecordingCoreAsync()
    {
        if (_recordingMeeting is null && !_recorder.HasActiveSession)
            return;

        StopRecordingButton.IsEnabled = false;
        RecordingStateTextBlock.Text = "Stopping safely…";
        ShowStatus("Stopping recording and closing the audio file…");

        CaptureResult result;
        try
        {
            result = await _recorder.StopAsync();
        }
        catch
        {
            if (_recorder.HasActiveSession)
            {
                StopRecordingButton.IsEnabled = true;
                RecordingStateTextBlock.Text = "Stop failed — retry Stop";
            }
            else
            {
                _recordingTimer.Stop();
                _recordingStopwatch.Stop();
                RecordingStateTextBlock.Text = "Capture stopped with an error";
                var failedMeetingId = _recordingMeeting?.Id;
                _recordingMeeting = null;
                SettingsButton.IsEnabled = true;
                SetRecordingComposerEnabled(true);
                if (failedMeetingId is not null)
                    _library.UpdateMeeting(failedMeetingId, fresh => fresh with { Status = "recording-error" });
            }
            throw;
        }

        _recordingTimer.Stop();
        _recordingStopwatch.Stop();
        RecordingLevelProgressBar.Value = 0;
        RecordingTimerTextBlock.Text = FormatClock(TimeSpan.FromSeconds(result.DurationSeconds));

        var stoppedMeetingId = _recordingMeeting?.Id;
        try
        {
            if (stoppedMeetingId is not null)
            {
                await Task.Run(() => _library.UpdateMeeting(stoppedMeetingId, fresh => fresh with
                {
                    DurationSeconds = result.DurationSeconds,
                    Status = "ready"
                }));
            }
            RecordingStateTextBlock.Text = "Ready";
        }
        catch
        {
            RecordingStateTextBlock.Text = "Audio saved; meeting status needs recovery";
            throw;
        }
        finally
        {
            // Capture has ended even if the metadata disk is full. Leaving the
            // old meeting active makes Stop and safe close fail on every retry.
            _recordingMeeting = null;
            SettingsButton.IsEnabled = true;
            SetRecordingComposerEnabled(true);
        }

        if (!string.IsNullOrWhiteSpace(result.Warning))
        {
            ShowStatus(result.Warning, isError: true);
            MessageBox.Show(this, result.Warning, "Recording warning", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        else
        {
            ShowStatus("Recording saved locally.");
        }

        await RefreshMeetingsAsync(stoppedMeetingId);
    }

    private void SetRecordingComposerEnabled(bool enabled)
    {
        RecordTitleTextBox.IsEnabled = enabled;
        RecordProjectComboBox.IsEnabled = enabled;
        MicrophoneComboBox.IsEnabled = enabled;
        MicrophoneOnlyRadio.IsEnabled = enabled;
        SystemAudioRadio.IsEnabled = enabled;
        StartRecordingButton.IsEnabled = enabled && _microphonesAvailable && _transcriptionTask is null;
        StopRecordingButton.IsEnabled = !enabled && (_recordingMeeting is not null || _recorder.HasActiveSession);

        if (_selectedMeeting is not null)
            TranscribeButton.IsEnabled = enabled && File.Exists(_library.GetAudioPath(_selectedMeeting.Id)) && _transcriptionTask is null;
    }

    private void RecordingTimer_Tick(object? sender, EventArgs e)
    {
        RecordingTimerTextBlock.Text = FormatClock(_recordingStopwatch.Elapsed);
    }

    private void Recorder_LevelChanged(float level)
    {
        var normalized = level <= 1f ? level * 100f : level;
        _ = Dispatcher.BeginInvoke(() => RecordingLevelProgressBar.Value = Math.Clamp(normalized, 0f, 100f));
    }

    private void Recorder_Warning(string warning)
    {
        _ = Dispatcher.BeginInvoke(() => ShowStatus(warning, isError: true));
    }

    private void NotesTextBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_loadingMeeting || _selectedMeeting is null)
            return;

        _notesDirty = true;
        NotesAutosaveTextBlock.Text = "Unsaved changes…";
    }

    private void NotesAutosaveTimer_Tick(object? sender, EventArgs e)
    {
        if (!_notesDirty)
            return;
        TrySaveCurrentNotes();
    }

    private bool TrySaveCurrentNotes()
    {
        if (!_notesDirty || _selectedMeeting is null)
            return true;

        try
        {
            _library.SaveNotes(_selectedMeeting.Id, NotesTextBox.Text);
            _notesDirty = false;
            NotesAutosaveTextBlock.Text = $"Saved {DateTime.Now:t}";
            return true;
        }
        catch (Exception ex)
        {
            NotesAutosaveTextBlock.Text = "Autosave failed";
            ShowError("Hall-e could not save your notes", ex);
            return false;
        }
    }

    private async void SaveMeetingMetadataButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null)
            return;

        try
        {
            if (!TrySaveCurrentNotes())
                return;

            var meetingId = _selectedMeeting.Id;
            var title = SelectedTitleTextBox.Text;
            var projectId = (SelectedProjectComboBox.SelectedItem as ProjectOption)?.Id;
            await Task.Run(() => _library.UpdateMeeting(meetingId, fresh => fresh with { Title = title, ProjectId = projectId }));
            await RefreshMeetingsAsync(meetingId);
            ShowStatus("Meeting details saved.");
        }
        catch (Exception ex)
        {
            ShowError("Could not save meeting details", ex);
        }
    }

    private void PlayPauseButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null)
            return;

        try
        {
            var audioPath = _library.GetAudioPath(_selectedMeeting.Id);
            if (!File.Exists(audioPath))
            {
                MessageBox.Show(this, "This meeting has no recorded audio.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            if (_playbackStarted && _playbackMeetingId == _selectedMeeting.Id)
            {
                _mediaPlayer.Pause();
                _playbackStarted = false;
                _playbackTimer.Stop();
                PlayPauseButton.Content = "Resume audio";
                return;
            }

            if (_playbackMeetingId != _selectedMeeting.Id)
            {
                StopPlayback();
                _playbackMeetingId = _selectedMeeting.Id;
                _mediaPlayer.Open(new Uri(audioPath, UriKind.Absolute));
            }

            _mediaPlayer.Play();
            _playbackStarted = true;
            _playbackTimer.Start();
            PlayPauseButton.Content = "Pause audio";
        }
        catch (Exception ex)
        {
            ShowError("Audio playback failed", ex);
        }
    }

    private void MediaPlayer_MediaOpened(object? sender, EventArgs e)
    {
        if (_mediaPlayer.NaturalDuration.HasTimeSpan)
        {
            var duration = _mediaPlayer.NaturalDuration.TimeSpan;
            PlaybackProgressBar.Maximum = Math.Max(1, duration.TotalSeconds);
            PlaybackTimeTextBlock.Text = $"00:00 / {FormatShortClock(duration)}";
        }
    }

    private void MediaPlayer_MediaEnded(object? sender, EventArgs e)
    {
        _mediaPlayer.Position = TimeSpan.Zero;
        _mediaPlayer.Pause();
        _playbackStarted = false;
        _playbackTimer.Stop();
        PlaybackProgressBar.Value = 0;
        PlayPauseButton.Content = "Play audio";
        UpdatePlaybackClock();
    }

    private void MediaPlayer_MediaFailed(object? sender, ExceptionEventArgs e)
    {
        StopPlayback();
        ShowError("Windows could not play this audio file", e.ErrorException);
    }

    private void PlaybackTimer_Tick(object? sender, EventArgs e) => UpdatePlaybackClock();

    private void UpdatePlaybackClock()
    {
        var position = _mediaPlayer.Position;
        var duration = _mediaPlayer.NaturalDuration.HasTimeSpan ? _mediaPlayer.NaturalDuration.TimeSpan : TimeSpan.Zero;
        PlaybackProgressBar.Value = Math.Min(PlaybackProgressBar.Maximum, Math.Max(0, position.TotalSeconds));
        PlaybackTimeTextBlock.Text = $"{FormatShortClock(position)} / {FormatShortClock(duration)}";
    }

    private void StopPlayback()
    {
        _playbackTimer.Stop();
        try
        {
            _mediaPlayer.Stop();
            _mediaPlayer.Close();
        }
        catch
        {
            // MediaPlayer cleanup is best-effort; user-facing failures are reported by MediaFailed.
        }
        _playbackStarted = false;
        _playbackMeetingId = null;
        PlaybackProgressBar.Value = 0;
        PlaybackTimeTextBlock.Text = "00:00 / 00:00";
        PlayPauseButton.Content = _selectedMeeting is not null && File.Exists(_library.GetAudioPath(_selectedMeeting.Id)) ? "Play audio" : "No audio";
    }

    private async void TranscribeButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null || _transcriptionStarting || _recordingStarting || _transcriptionTask is { IsCompleted: false })
            return;

        if (_recordingMeeting is not null || _recorder.HasActiveSession)
        {
            MessageBox.Show(this, "Stop the active recording before starting transcription.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var meetingId = _selectedMeeting.Id;
        var audioPath = _library.GetAudioPath(meetingId);
        if (!File.Exists(audioPath))
        {
            MessageBox.Show(this, "This meeting has no audio to transcribe.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var provider = (TranscriptionProviderComboBox.SelectedItem as ProviderOption)?.Provider ?? TranscriptionProvider.Local;
        _transcriptionStarting = true;
        SetTranscriptionUi(running: true);
        try
        {
            if (!TrySaveCurrentNotes())
                return;

            var settings = await Task.Run(_library.LoadSettings);
            settings = settings with { Provider = provider };

            if (!CanUseProvider(provider, settings, out var providerIssue))
            {
                MessageBox.Show(this, providerIssue, "Transcription setup required", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            await Task.Run(() => _library.SaveSettings(settings));
            await Task.Run(() => _library.UpdateMeeting(meetingId, fresh => fresh with { Status = "transcribing", TranscriptionError = null }));
            var fresh = await Task.Run(() => _library.GetMeeting(meetingId));

            _transcriptionCts = new CancellationTokenSource();
            var progress = new Progress<string>(message =>
            {
                TranscriptionProgressTextBlock.Text = string.IsNullOrWhiteSpace(message) ? "Transcribing…" : message;
                ShowStatus(TranscriptionProgressTextBlock.Text);
            });

            SetTranscriptionUi(running: true);
            _transcriptionTask = RunTranscriptionAsync(fresh, settings, progress, _transcriptionCts.Token);
            _transcriptionStarting = false;
            await _transcriptionTask;
        }
        catch (Exception ex)
        {
            ShowError("Could not start transcription", ex);
        }
        finally
        {
            _transcriptionStarting = false;
            _transcriptionTask = null;
            _transcriptionCts?.Dispose();
            _transcriptionCts = null;
            SetTranscriptionUi(running: false);

            try
            {
                await RefreshMeetingsAsync(meetingId);
            }
            catch (Exception refreshError)
            {
                ShowError("Transcription finished, but the meeting view could not refresh", refreshError);
            }
        }
    }

    private async Task RunTranscriptionAsync(MeetingRecord meeting, AppSettings settings, IProgress<string> progress, CancellationToken cancellationToken)
    {
        try
        {
            var result = await _transcriptionService.TranscribeAsync(meeting, settings, progress, cancellationToken);
            await Task.Run(() => _library.SaveTranscript(meeting.Id, result.Text));

            // Merge status with the latest metadata under the store lock.
            await Task.Run(() => _library.UpdateMeeting(meeting.Id, latest => latest with
            {
                Status = "ready",
                TranscriptionError = null,
                TranscriptProvider = result.Provider
            }));

            TranscriptionProgressTextBlock.Text = "Transcription complete";
            ShowStatus("Transcription saved locally.");
        }
        catch (OperationCanceledException)
        {
            await Task.Run(() => _library.UpdateMeeting(meeting.Id, latest => latest with
            {
                Status = "transcription-cancelled",
                TranscriptionError = null
            }));
            TranscriptionProgressTextBlock.Text = "Transcription cancelled · recording preserved";
            ShowStatus("Transcription cancelled. Audio and any saved remote job metadata were preserved.");
        }
        catch (Exception ex)
        {
            try
            {
                await Task.Run(() => _library.UpdateMeeting(meeting.Id, latest => latest with
                {
                    Status = "transcription-error",
                    TranscriptionError = ex.Message
                }));
            }
            catch (Exception metadataError)
            {
                ShowError("Transcription failed and Hall-e could not save the updated local status", metadataError);
            }

            TranscriptionProgressTextBlock.Text = "Transcription failed · retry is available";
            ShowError("Transcription failed. The recording was preserved", ex);
        }
    }

    private bool CanUseProvider(TranscriptionProvider provider, AppSettings settings, out string issue)
    {
        issue = string.Empty;

        if (provider == TranscriptionProvider.Local)
            return true;

        if (!_credentials.HasKey(provider))
        {
            issue = $"Add and validate a {ProviderName(provider)} API key in Settings first. Hall-e will not upload audio without a validated saved key.";
            return false;
        }

        if (provider == TranscriptionProvider.Deepgram && !settings.DeepgramConsent)
        {
            issue = "Deepgram consent is off. Enable the Deepgram audio-upload consent in Settings before using this provider.";
            return false;
        }

        if (provider == TranscriptionProvider.Speechmatics)
        {
            if (!settings.SpeechmaticsConsent)
            {
                issue = "Speechmatics consent is off. Enable the Speechmatics audio-upload consent in Settings before using this provider.";
                return false;
            }

            if (!settings.SpeechmaticsTrainingDisabled)
            {
                issue = "Confirm the Speechmatics training-disabled setting in Settings before sending audio.";
                return false;
            }

            if (settings.SpeechmaticsRegion is not ("eu" or "us"))
            {
                issue = "Choose the Speechmatics EU or US processing region in Settings.";
                return false;
            }
        }

        return true;
    }

    private void CancelTranscriptionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_transcriptionCts is null)
            return;
        CancelTranscriptionButton.IsEnabled = false;
        TranscriptionProgressTextBlock.Text = "Cancelling safely…";
        _transcriptionCts.Cancel();
    }

    private void SetTranscriptionUi(bool running)
    {
        TranscribeButton.IsEnabled = !running && _selectedMeeting is not null && _recordingMeeting is null && File.Exists(_library.GetAudioPath(_selectedMeeting.Id));
        CancelTranscriptionButton.IsEnabled = running;
        TranscriptionProviderComboBox.IsEnabled = !running;
        TranscriptionProgressBar.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
        StartRecordingButton.IsEnabled = !running && _microphonesAvailable && _recordingMeeting is null;
        if (!running && TranscriptionProgressTextBlock.Text.Contains("Cancelling", StringComparison.OrdinalIgnoreCase))
            TranscriptionProgressTextBlock.Text = "No transcription running";
    }

    private async void DeleteAudioButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null)
            return;

        var meetingId = _selectedMeeting.Id;
        if (_recordingMeeting?.Id == meetingId || _selectedMeeting.Status is "recording" or "transcribing")
        {
            MessageBox.Show(this, "Stop the active recording or transcription before deleting audio.", "Hall-e", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var confirmation = MessageBox.Show(
            this,
            $"Delete the recorded audio for “{_selectedMeeting.Title}”?\n\nNotes, transcript, and meeting metadata will be kept. The audio deletion cannot be undone.",
            "Delete meeting audio",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);

        if (confirmation != MessageBoxResult.Yes)
            return;

        try
        {
            if (!TrySaveCurrentNotes())
                return;
            StopPlayback();
            await Task.Run(() => _library.DeleteAudio(meetingId));
            var selected = await Task.Run(() => _library.GetMeeting(meetingId));
            _selectedMeeting = null;
            await RefreshMeetingsAsync(meetingId);
            await SwitchMeetingAsync(selected);
            ShowStatus("Audio deleted. Notes and transcript were preserved.");
        }
        catch (Exception ex)
        {
            ShowError("Could not delete the meeting audio", ex);
        }
    }

    private async void ExportMarkdownButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null)
            return;

        try
        {
            if (!TrySaveCurrentNotes())
                return;

            var meeting = _selectedMeeting;
            var content = await Task.Run(() => _library.ExportMarkdown(meeting.Id));
            var dialog = new SaveFileDialog
            {
                Title = "Export Hall-e meeting",
                Filter = "Markdown file (*.md)|*.md",
                AddExtension = true,
                DefaultExt = ".md",
                FileName = SafeFileName(meeting.Title) + ".md"
            };

            if (dialog.ShowDialog(this) != true)
                return;

            await File.WriteAllTextAsync(dialog.FileName, content, Encoding.UTF8);
            ShowStatus($"Exported “{Path.GetFileName(dialog.FileName)}”.");
        }
        catch (Exception ex)
        {
            ShowError("Could not export this meeting", ex);
        }
    }

    private void OpenMeetingFolderButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedMeeting is null)
            return;

        try
        {
            OpenKnownFolder(_library.GetMeetingDirectory(_selectedMeeting.Id));
        }
        catch (Exception ex)
        {
            ShowError("Could not open the meeting folder", ex);
        }
    }

    private void OpenLibraryButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            OpenKnownFolder(_library.RootPath);
        }
        catch (Exception ex)
        {
            ShowError("Could not open the Hall-e library folder", ex);
        }
    }

    private async void SettingsButton_Click(object sender, RoutedEventArgs e)
    {
        await OpenSettingsAsync();
    }

    private async void OnboardingSettingsButton_Click(object sender, RoutedEventArgs e)
    {
        await OpenSettingsAsync();
    }

    private async Task OpenSettingsAsync()
    {
        try
        {
            var window = new SettingsWindow(_library, _credentials, _transcriptionService) { Owner = this };
            window.ShowDialog();
            var settings = await Task.Run(_library.LoadSettings);
            SetSelectedProvider(settings.Provider);
            if (_selectedMeeting is null)
                ShowStatus("Settings updated.");
        }
        catch (Exception ex)
        {
            ShowError("Could not open settings", ex);
        }
    }

    private async void CompleteOnboardingButton_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var settings = await Task.Run(_library.LoadSettings);
            await Task.Run(() => _library.SaveSettings(settings with { OnboardingCompleted = true }));
            OnboardingOverlay.Visibility = Visibility.Collapsed;
            ShowStatus("Hall-e is ready. Microphone-only capture remains the default.");
        }
        catch (Exception ex)
        {
            ShowError("Could not save onboarding preferences", ex);
        }
    }

    private async void MainWindow_Closing(object? sender, CancelEventArgs e)
    {
        if (_allowClose)
            return;
        if (_recordingStarting || _transcriptionStarting)
        {
            e.Cancel = true;
            ShowStatus("Hall-e is starting an operation. Close again after it starts or finishes.");
            return;
        }

        var recordingActive = _recordingMeeting is not null || _recorder.HasActiveSession;
        var transcriptionActive = _transcriptionTask is { IsCompleted: false };

        if (!recordingActive && !transcriptionActive)
        {
            if (!TrySaveCurrentNotes())
            {
                e.Cancel = true;
                return;
            }

            DisposeUiResources();
            _allowClose = true;
            return;
        }

        e.Cancel = true;
        if (_closeInProgress)
            return;

        var message = recordingActive && transcriptionActive
            ? "A recording and a transcription operation are active. Hall-e will stop the recording safely, cancel transcription, preserve its job metadata, save notes, and then close. Continue?"
            : recordingActive
                ? "A recording is active. Hall-e must stop it safely and close the audio file before exiting. Stop recording and close?"
                : "Transcription is active. Hall-e will cancel it, preserve the recording and any saved remote job metadata, save notes, and then close. Continue?";

        var confirmation = MessageBox.Show(this, message, "Close Hall-e safely", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (confirmation != MessageBoxResult.Yes)
            return;

        _closeInProgress = true;
        try
        {
            if (recordingActive)
                await StopRecordingAsync();

            if (_transcriptionTask is { IsCompleted: false })
            {
                _transcriptionCts?.Cancel();
                await _transcriptionTask;
            }

            if (!TrySaveCurrentNotes())
            {
                _closeInProgress = false;
                return;
            }

            DisposeUiResources();
            _allowClose = true;
            Close();
        }
        catch (Exception ex)
        {
            _closeInProgress = false;
            ShowError("Hall-e could not complete the safe close operation. The window will remain open", ex);
        }
    }

    private void DisposeUiResources()
    {
        if (_resourcesDisposed)
            return;

        _resourcesDisposed = true;
        _notesAutosaveTimer.Stop();
        _searchTimer.Stop();
        _recordingTimer.Stop();
        StopPlayback();
        _recorder.LevelChanged -= Recorder_LevelChanged;
        _recorder.Warning -= Recorder_Warning;
        _recorder.Dispose();
    }

    private void RestoreMeetingSelection()
    {
        _suppressMeetingSelection = true;
        MeetingsListBox.SelectedItem = _selectedMeeting is null
            ? null
            : MeetingsListBox.Items.OfType<MeetingListItem>().FirstOrDefault(item => item.Meeting.Id == _selectedMeeting.Id);
        _suppressMeetingSelection = false;
    }

    private static void SelectProjectOption(ComboBox comboBox, string? projectId, bool preferAll)
    {
        var items = comboBox.ItemsSource?.Cast<ProjectOption>().ToArray() ?? [];
        ProjectOption? match;
        if (projectId is null)
            match = items.FirstOrDefault(i => i.Id is null && i.IsAll == preferAll);
        else
            match = items.FirstOrDefault(i => i.Id == projectId);

        comboBox.SelectedItem = match ?? items.FirstOrDefault();
    }

    private void SetSelectedProvider(TranscriptionProvider provider)
    {
        TranscriptionProviderComboBox.SelectedItem = ProviderOptions.First(option => option.Provider == provider);
    }

    private static string FriendlyStatus(string status) => status switch
    {
        "ready" => "Ready",
        "recording" => "Recording",
        "recording-error" => "Recording needs attention",
        "transcribing" => "Transcribing",
        "transcription-error" => "Transcription needs attention",
        "transcription-cancelled" => "Transcription paused",
        "audio-deleted" => "Audio deleted",
        _ => status.Replace('-', ' ')
    };

    private static string ProviderName(TranscriptionProvider provider) => provider switch
    {
        TranscriptionProvider.Deepgram => "Deepgram",
        TranscriptionProvider.Speechmatics => "Speechmatics",
        _ => "Windows local speech"
    };

    private static string FormatClock(TimeSpan value) =>
        $"{(int)value.TotalHours:00}:{value.Minutes:00}:{value.Seconds:00}";

    private static string FormatShortClock(TimeSpan value) =>
        value.TotalHours >= 1
            ? $"{(int)value.TotalHours:0}:{value.Minutes:00}:{value.Seconds:00}"
            : $"{value.Minutes:00}:{value.Seconds:00}";

    private static string SafeFileName(string title)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var sanitized = new string(title.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray()).Trim();
        return string.IsNullOrWhiteSpace(sanitized) ? "Hall-e meeting" : sanitized;
    }

    private static void OpenKnownFolder(string path)
    {
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private void ShowStatus(string message, bool isError = false)
    {
        StatusTextBlock.Text = message;
        StatusTextBlock.Foreground = (Brush)FindResource(isError ? "DangerBrush" : "MutedTextBrush");
    }

    private void ShowError(string operation, Exception ex)
    {
        var message = string.IsNullOrWhiteSpace(ex.Message) ? ex.GetType().Name : ex.Message;
        ShowStatus($"{operation}: {message}", isError: true);
        MessageBox.Show(this, $"{operation}.\n\n{message}", "Hall-e error", MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
