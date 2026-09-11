using HallE.Core;
using NAudio.Wave;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

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

    internal void VerifySmokeThemeContrast()
    {
        if (!_smokeMode) throw new InvalidOperationException("This check requires isolated smoke-test storage.");
        UpdateLayout();

        // Inspect the rendered label, not just the control's Foreground: an
        // implicit TextBlock style can override the foreground inside a template.
        VerifySmokeLabelContrast(this, "Hall-e", Background);
        foreach (var button in new[] { TranscribeButton, OpenLibraryButton, DeleteAudioButton })
        {
            if (button.Template.FindName("Border", button) is not Border border)
                throw new InvalidOperationException("The button template did not render its background.");
            VerifySmokeLabelContrast(button, (string)button.Content, border.Background);
        }

        var originalSelection = MeetingDetailsTabControl.SelectedIndex;
        try
        {
            for (var selected = 0; selected < MeetingDetailsTabControl.Items.Count; selected++)
            {
                MeetingDetailsTabControl.SelectedIndex = selected;
                UpdateLayout();
                foreach (TabItem tab in MeetingDetailsTabControl.Items)
                {
                    if (tab.Template.FindName("TabBorder", tab) is not Border border)
                        throw new InvalidOperationException("The tab template did not render its background.");
                    VerifySmokeLabelContrast(tab, (string)tab.Header, border.Background);
                }
            }
        }
        finally
        {
            MeetingDetailsTabControl.SelectedIndex = originalSelection;
            UpdateLayout();
        }
    }

    private static void VerifySmokeLabelContrast(DependencyObject root, string text, Brush background)
    {
        var label = SmokeVisualDescendants<TextBlock>(root).FirstOrDefault(block => block.Text == text)
            ?? throw new InvalidOperationException($"The rendered label '{text}' was not found.");
        if (label.Foreground is not SolidColorBrush foreground || background is not SolidColorBrush surface
            || foreground.Color.A != 255 || surface.Color.A != 255)
            throw new InvalidOperationException($"The label '{text}' requires opaque theme colors.");

        var first = SmokeLuminance(foreground.Color);
        var second = SmokeLuminance(surface.Color);
        var contrast = (Math.Max(first, second) + 0.05) / (Math.Min(first, second) + 0.05);
        if (contrast < 4.5)
            throw new InvalidOperationException($"The rendered label '{text}' has insufficient contrast ({contrast:F2}:1).");
    }

    private static double SmokeLuminance(Color color)
    {
        static double Linear(byte channel)
        {
            var value = channel / 255d;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
    }

    private static IEnumerable<T> SmokeVisualDescendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            if (child is T match) yield return match;
            foreach (var descendant in SmokeVisualDescendants<T>(child)) yield return descendant;
        }
    }
}
