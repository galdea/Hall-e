using System.Diagnostics;
using HallE.Core;
using NAudio.Wave;

namespace HallE.Windows.Services;

public static class RecordingRecoveryService
{
    /// <summary>Recover each recording independently, retaining unreadable audio for a later repair.</summary>
    public static int RecoverInterruptedMeetings(LibraryStore library)
    {
        var failures = 0;
        foreach (var meeting in library.ListMeetings())
        {
            if (meeting.Status is not ("recording" or "recording-error" or "transcribing")) continue;
            var status = "transcription-cancelled";
            var duration = meeting.DurationSeconds;
            var message = "Transcription was interrupted. Recorded audio and any remote job ID were preserved.";
            if (meeting.Status is "recording" or "recording-error")
            {
                status = "recording-error";
                message = "Recording was interrupted. Original files were preserved; recovered audio is available when possible.";
                try
                {
                    AudioRecorder.RecoverInterruptedAudio(library.GetMeetingDirectory(meeting.Id));
                    var audioPath = library.GetAudioPath(meeting.Id);
                    if (File.Exists(audioPath))
                    {
                        using var reader = new WaveFileReader(audioPath);
                        var recoveredDuration = reader.TotalTime.TotalSeconds;
                        if (!double.IsFinite(recoveredDuration) || recoveredDuration <= 0)
                            throw new InvalidDataException("The recording contains no playable audio.");
                        duration = recoveredDuration;
                        status = "ready";
                    }
                }
                catch (Exception error)
                {
                    Trace.TraceError($"Recording recovery failed for {meeting.Id}: {error}");
                    message = "The interrupted recording could not be read. Original audio was preserved for recovery.";
                }
            }

            try
            {
                library.UpdateMeeting(meeting.Id, fresh => fresh with
                {
                    Status = status, DurationSeconds = duration, TranscriptionError = message
                });
                if (status == "recording-error") failures++;
            }
            catch (Exception error)
            {
                failures++;
                Trace.TraceError($"Recording recovery status could not be saved for {meeting.Id}: {error}");
            }
        }
        return failures;
    }
}
