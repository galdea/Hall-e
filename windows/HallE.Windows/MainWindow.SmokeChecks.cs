using HallE.Core;
using NAudio.Wave;

namespace HallE.Windows;

public partial class MainWindow
{
    // Exercise the real meeting view using synthetic data in smoke-test storage.
    // This never activates an audio device or a cloud transcription provider.
    internal async Task VerifySmokeMeetingRefreshAsync()
    {
        if (!_smokeMode) throw new InvalidOperationException("This check requires isolated smoke-test storage.");
        var meeting = _library.CreateMeeting("Installation check", null, "en-US", CaptureMode.Microphone);
        _library.UpdateMeeting(meeting.Id, fresh => fresh with { Status = "recording" });
        await RefreshMeetingsAsync(meeting.Id);
        if (PlayPauseButton.IsEnabled || TranscribeButton.IsEnabled)
            throw new InvalidOperationException("An active recording must not be playable or transcribable.");

        // Generate a silent fixture, not a captured recording.
        using (var writer = new WaveFileWriter(_library.GetAudioPath(meeting.Id), new WaveFormat(48000, 16, 1)))
            writer.Write(new byte[9600], 0, 9600);
        _library.UpdateMeeting(meeting.Id, fresh => fresh with { Status = "ready", DurationSeconds = 0.1 });
        const string notes = "Synthetic installation check. No microphone or cloud provider was used.";
        NotesTextBox.Text = notes;
        _library.SaveTranscript(meeting.Id, "Synthetic transcript for startup verification.");
        await RefreshMeetingsAsync(meeting.Id);

        if (_selectedMeeting?.Status != "ready" || !PlayPauseButton.IsEnabled || !TranscribeButton.IsEnabled
            || NotesTextBox.Text != notes || _library.GetNotes(meeting.Id) != notes
            || TranscriptTextBox.Text != _library.GetTranscript(meeting.Id))
            throw new InvalidOperationException("The completed recording did not refresh correctly or preserve notes.");

        NotesTextBox.Text = notes + " Notes were edited and saved again.";
        await RefreshMeetingsAsync(meeting.Id);
        if (NotesTextBox.Text != _library.GetNotes(meeting.Id))
            throw new InvalidOperationException("A repeated meeting refresh lost the current notes.");
    }
}
