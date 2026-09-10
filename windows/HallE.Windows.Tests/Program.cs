using System.Text;
using System.Text.Json;
using HallE.Core;
using HallE.Windows.Services;
using NAudio.Wave;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Run Windows service checks on Windows.");
var root = Path.Combine(Path.GetTempPath(), "hall-e-service-tests-" + Guid.NewGuid().ToString("N"));
var passed = 0;
try
{
    var library = new LibraryStore(root);
    var credentials = new CredentialStore(root);
    const string fixtureKey = "hall-e-test-fixture-not-a-real-api-key";
    credentials.SaveKey(TranscriptionProvider.Deepgram, fixtureKey);
    Check(credentials.GetKey(TranscriptionProvider.Deepgram) == fixtureKey, "DPAPI credential survives round trip for the current Windows user");
    var encrypted = File.ReadAllBytes(Path.Combine(root, ".credentials", "deepgram.dpapi"));
    Check(!Encoding.UTF8.GetString(encrypted).Contains(fixtureKey), "Credential file does not contain plaintext key");
    try { credentials.SaveKey(TranscriptionProvider.Deepgram, "invalid key"); throw new Exception("Expected validation failure"); }
    catch (ArgumentException) { }
    Check(credentials.GetKey(TranscriptionProvider.Deepgram) == fixtureKey, "Invalid replacement preserves existing credential");
    credentials.DeleteKey(TranscriptionProvider.Deepgram);
    Check(!credentials.HasKey(TranscriptionProvider.Deepgram), "Credential deletion removes saved key");

    var meeting = library.CreateMeeting("Recovery fixture", null, "en-US", CaptureMode.MicrophoneAndSystem);
    var directory = library.GetMeetingDirectory(meeting.Id);
    WriteTrack(Path.Combine(directory, ".audio.wav.halle-mic.partial.wav"), 1, .25f);
    WriteTrack(Path.Combine(directory, ".audio.wav.halle-system.partial.wav"), 2, .125f);
    File.WriteAllText(Path.Combine(directory, ".audio.wav.halle-recording.json"), JsonSerializer.Serialize(new
    {
        TargetFileName = "audio.wav",
        MicrophoneFileName = ".audio.wav.halle-mic.partial.wav",
        SystemFileName = ".audio.wav.halle-system.partial.wav",
        Mode = CaptureMode.MicrophoneAndSystem,
        StartedUtc = DateTimeOffset.UtcNow
    }));
    AudioRecorder.RecoverInterruptedAudio(directory);
    using (var recovered = new AudioFileReader(library.GetAudioPath(meeting.Id)))
    {
        Check(Math.Abs(recovered.TotalTime.TotalSeconds - .1) < .01, "Interrupted recording retains expected duration");
        var samples = new float[2];
        Check(recovered.Read(samples, 0, 2) == 2 && samples.All(s => Math.Abs(s - .375) < .002), "Recovery correctly mixes microphone and system samples");
    }
    Check(!Directory.EnumerateFiles(directory, "*.partial.wav").Any(), "Successful recovery removes source tracks only after finalization");

    var failed = library.CreateMeeting("Unrecoverable fixture", null, "en-US", CaptureMode.Microphone);
    var failedDir = library.GetMeetingDirectory(failed.Id);
    var original = Path.Combine(failedDir, ".audio.wav.halle-mic.partial.wav");
    File.WriteAllText(original, "unreadable audio fixture");
    File.WriteAllText(Path.Combine(failedDir, ".audio.wav.halle-recording.json"), JsonSerializer.Serialize(new
    {
        TargetFileName = "audio.wav", MicrophoneFileName = Path.GetFileName(original),
        SystemFileName = (string?)null, Mode = CaptureMode.Microphone, StartedUtc = DateTimeOffset.UtcNow
    }));
    AudioRecorder.RecoverInterruptedAudio(failedDir);
    Check(File.ReadAllText(original) == "unreadable audio fixture", "Failed recovery preserves original audio");

    var transcription = new TranscriptionService(library, credentials);
    await MustReject(() => transcription.TranscribeAsync(meeting, new AppSettings { Provider = TranscriptionProvider.Deepgram }), "consent");
    await MustReject(() => transcription.TranscribeAsync(meeting, new AppSettings { Provider = TranscriptionProvider.Speechmatics }), "consent");
    credentials.SaveKey(TranscriptionProvider.Speechmatics, fixtureKey);
    library.SaveMeeting(meeting with { SpeechmaticsSubmissionUncertain = true, Status = "transcribing" });
    await MustReject(() => transcription.TranscribeAsync(meeting, new AppSettings
    {
        Provider = TranscriptionProvider.Speechmatics, SpeechmaticsConsent = true, SpeechmaticsTrainingDisabled = true
    }), "previous");
    Check(File.Exists(library.GetAudioPath(meeting.Id)), "Consent failures preserve recorded audio");
    Console.WriteLine($"PASS: {passed} Windows service checks; no microphone or cloud job used.");
    return 0;
}
catch (Exception e) { Console.Error.WriteLine(e); return 1; }
finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }

void Check(bool condition, string name)
{
    if (!condition) throw new Exception("FAIL: " + name);
    Console.WriteLine("PASS: " + name);
    passed++;
}
async Task MustReject(Func<Task<TranscriptionResult>> operation, string messagePart)
{
    try { await operation(); }
    catch (InvalidOperationException e) when (e.Message.Contains(messagePart, StringComparison.OrdinalIgnoreCase))
    {
        Check(true, "Transcription guard rejects request before network: " + messagePart);
        return;
    }
    throw new Exception("Expected transcription rejection: " + messagePart);
}
void WriteTrack(string path, int channels, float level)
{
    // Standard PCM WAV with unfinalized RIFF/data lengths, as after a crash.
    using var writer = new BinaryWriter(File.Create(path));
    writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(0);
    writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
    writer.Write((short)1); writer.Write((short)channels); writer.Write(48000);
    writer.Write(48000 * channels * 2); writer.Write((short)(channels * 2)); writer.Write((short)16);
    writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(0);
    for (var i = 0; i < 4800 * channels; i++) writer.Write((short)(level * 32767));
}
