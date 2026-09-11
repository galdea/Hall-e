using HallE.Core;

var root = Path.Combine(Path.GetTempPath(), "hall-e-core-tests-" + Guid.NewGuid().ToString("N"));
var passed = 0;
try
{
    var store = new LibraryStore(root);
    Check(store.ListMeetings().Count == 0 && store.ListProjects().Count == 0, "Fresh profile contains no personal/sample data");
    var settings = store.LoadSettings();
    Check(settings.Provider == TranscriptionProvider.Local && !settings.DeepgramConsent && !settings.SpeechmaticsConsent,
        "Fresh profile defaults to local speech with no cloud consent");
    var project = store.CreateProject("Research");
    Check(store.CreateProject("research").Id == project.Id, "Project names are deduplicated");
    var meeting = store.CreateMeeting("Team meeting", project.Id, "es-CL", CaptureMode.Microphone);
    store.SaveNotes(meeting.Id, "¿Qué decidimos?\nOne decision.\n日本語");
    store.SaveTranscript(meeting.Id, "Speaker 1: Local files survive.");
    store.SaveMeeting(meeting with { DurationSeconds = 3661, TranscriptProvider = "Local Windows speech" });
    var reopened = new LibraryStore(root);
    Check(reopened.GetNotes(meeting.Id).Contains("日本語") && reopened.GetTranscript(meeting.Id).Contains("Speaker 1"), "Unicode notes and transcripts survive restart");
    Check(reopened.GetMeeting(meeting.Id).DurationSeconds == 3661, "Metadata survives restart");
    store.SaveMeeting(store.GetMeeting(meeting.Id) with { SpeechmaticsSubmissionUncertain = true });
    reopened.SaveMeeting(reopened.GetMeeting(meeting.Id) with { Status = "transcription-cancelled" });
    Check(new LibraryStore(root).GetMeeting(meeting.Id).SpeechmaticsSubmissionUncertain,
        "Uncertain paid submission survives cancellation status updates and restart");
    Check(reopened.ListMeetings("decidimos").Count == 1 && reopened.ListMeetings("survive").Count == 1 && reopened.ListMeetings("absent").Count == 0,
        "Search covers notes and transcripts");
    var markdown = reopened.ExportMarkdown(meeting.Id);
    Check(markdown.Contains("## Notes") && markdown.Contains("## Transcript") && markdown.Contains("01:01:01") && markdown.Contains("Research"),
        "Markdown export includes notes, transcript, project and duration");
    File.WriteAllBytes(reopened.GetAudioPath(meeting.Id), new byte[44]);
    reopened.DeleteAudio(meeting.Id);
    Check(!File.Exists(reopened.GetAudioPath(meeting.Id)) && reopened.GetNotes(meeting.Id).Length > 0 && reopened.GetTranscript(meeting.Id).Length > 0,
        "Deleting audio preserves notes and transcript");
    Throws<ArgumentException>(() => reopened.GetAudioPath("../../secrets"), "Reject path traversal");
    Throws<ArgumentException>(() => reopened.SaveNotes("bad/id", "x"), "Reject invalid note identifiers");
    Throws<ArgumentException>(() => reopened.CreateMeeting("test", Guid.NewGuid().ToString("N"), "en-US", CaptureMode.Microphone), "Reject nonexistent project");
    Throws<ArgumentOutOfRangeException>(() => reopened.SaveMeeting(meeting with { DurationSeconds = double.NaN }), "Reject invalid duration");
    reopened.SaveMeeting(meeting with { Status = "recording" });
    Throws<InvalidOperationException>(() => reopened.DeleteAudio(meeting.Id), "Protect active recording from deletion");
    reopened.SaveMeeting(meeting with { Status = "ready" });
    reopened.SaveNotes(meeting.Id, "First draft");
    reopened.SaveNotes(meeting.Id, "Second draft");
    Check(File.ReadAllText(Path.Combine(reopened.GetMeetingDirectory(meeting.Id), "notes.md.bak")) == "First draft", "Notes preserve previous draft backup");
    store.SaveSettings(new AppSettings { Language = "es-ES" });
    store.SaveSettings(new AppSettings { Language = "en-US" });
    File.WriteAllText(Path.Combine(root, "settings.json"), "{truncated");
    Check(store.LoadSettings().Language == "es-ES", "Recover corrupt settings from backup without enabling cloud");
    store.SaveSettings(new AppSettings { Language = "fr-FR" });
    Check(store.LoadSettings().Language == "fr-FR" && File.ReadAllText(Path.Combine(root, "settings.json.bak")).Contains("es-ES"),
        "Saving recovered settings preserves the last valid backup");
    Parallel.For(0, 12, i => store.SaveNotes(meeting.Id, "Concurrent note " + i));
    Check(store.GetNotes(meeting.Id).StartsWith("Concurrent note "), "Concurrent note saves remain complete");
    Parallel.Invoke(
        () => store.UpdateMeeting(meeting.Id, current => current with { Title = "Edited during transcription" }),
        () => store.UpdateMeeting(meeting.Id, current => current with { Status = "ready", DurationSeconds = 42 }),
        () => store.UpdateMeeting(meeting.Id, current => current with { RemoteJobId = "saved-job", RemoteJobRegion = "eu1" }));
    var merged = store.GetMeeting(meeting.Id);
    Check(merged.Title == "Edited during transcription" && merged.DurationSeconds == 42
        && merged.RemoteJobId == "saved-job" && merged.RemoteJobRegion == "eu1",
        "Atomic status updates preserve concurrent title edits and remote job checkpoints");
    Check(!Directory.EnumerateFiles(root, "*.tmp", SearchOption.AllDirectories).Any(), "Atomic writes leave no temporary files");
    Console.WriteLine($"PASS: {passed} Windows core checks.");
    return 0;
}
catch (Exception e)
{
    Console.Error.WriteLine(e);
    return 1;
}
finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

void Check(bool condition, string description)
{
    if (!condition) throw new Exception("FAIL: " + description);
    Console.WriteLine("PASS: " + description);
    passed++;
}
void Throws<T>(Action action, string description) where T : Exception
{
    try { action(); }
    catch (T) { Check(true, description); return; }
    throw new Exception("FAIL (expected " + typeof(T).Name + "): " + description);
}
