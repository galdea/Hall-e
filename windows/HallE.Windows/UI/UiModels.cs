using HallE.Core;

namespace HallE.Windows.UI;

public sealed record ProjectOption(string? Id, string DisplayName, bool IsAll = false)
{
    public override string ToString() => DisplayName;
}

public sealed record ProviderOption(TranscriptionProvider Provider, string DisplayName)
{
    public override string ToString() => DisplayName;
}

public sealed record RegionOption(string Id, string DisplayName)
{
    public override string ToString() => DisplayName;
}

public sealed record MeetingListItem(MeetingRecord Meeting, string ProjectName)
{
    public string StatusLabel => Meeting.Status switch
    {
        "recording" => "Recording",
        "transcribing" => "Transcribing",
        "transcription-error" => "Transcription needs attention",
        "transcription-cancelled" => "Transcription paused",
        "audio-deleted" => "Audio deleted",
        _ => Meeting.DisplayDuration
    };
}
