namespace HallE.Core;

public enum CaptureMode { Microphone, MicrophoneAndSystem }
public enum TranscriptionProvider { Local, Deepgram, Speechmatics }

public sealed record ProjectRecord(string Id, string Name);

public sealed record MeetingRecord
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public string Title { get; init; } = "New meeting";
    public string? ProjectId { get; init; }
    public DateTimeOffset CreatedUtc { get; init; } = DateTimeOffset.UtcNow;
    public double DurationSeconds { get; init; }
    public string Language { get; init; } = "en-US";
    public CaptureMode CaptureMode { get; init; }
    public string Status { get; init; } = "ready";
    public string? TranscriptionError { get; init; }
    public string? RemoteJobId { get; init; }
    public string? RemoteJobRegion { get; init; }
    public bool SpeechmaticsSubmissionUncertain { get; init; }
    public string? TranscriptProvider { get; init; }
    public string DisplayDate => CreatedUtc.ToLocalTime().ToString("g");
    public string DisplayDuration => TimeSpan.FromSeconds(Math.Max(0, DurationSeconds)).ToString(@"hh\:mm\:ss");
}

public sealed record AppSettings
{
    public string Language { get; init; } = "en-US";
    public TranscriptionProvider Provider { get; init; } = TranscriptionProvider.Local;
    public bool DeepgramConsent { get; init; }
    public bool SpeechmaticsConsent { get; init; }
    public string SpeechmaticsRegion { get; init; } = "eu";
    public bool SpeechmaticsTrainingDisabled { get; init; }
    public bool OnboardingCompleted { get; init; }
}

public sealed record AudioDevice(string Id, string Name)
{
    public override string ToString() => Name;
}
public sealed record CaptureResult(double DurationSeconds, string? Warning = null);
public sealed record TranscriptionResult(string Text, string Provider);
