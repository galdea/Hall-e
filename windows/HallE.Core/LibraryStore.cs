using System.Globalization;
using System.Text;
using System.Text.Json;

namespace HallE.Core;

/// <summary>Local, atomic storage. Audio deletion never removes notes or transcripts.</summary>
public sealed class LibraryStore
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    private readonly object gate = new();
    public string RootPath { get; }

    public LibraryStore(string rootPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        RootPath = Path.GetFullPath(rootPath);
        Directory.CreateDirectory(Path.Combine(RootPath, "Meetings"));
    }

    public IReadOnlyList<MeetingRecord> ListMeetings(string? query = null)
    {
        lock (gate)
        {
            var meetings = new List<MeetingRecord>();
            foreach (var directory in Directory.EnumerateDirectories(Path.Combine(RootPath, "Meetings")))
            {
                var id = Path.GetFileName(directory);
                if (!Guid.TryParseExact(id, "N", out _)) continue;
                var file = Path.Combine(directory, "meeting.json");
                if (!File.Exists(file) && !File.Exists(file + ".bak")) continue;
                var meeting = ReadJson<MeetingRecord>(file);
                if (meeting.Id != id) throw new InvalidDataException("A meeting has inconsistent metadata. Its files have been preserved.");
                if (!string.IsNullOrWhiteSpace(query) &&
                    !meeting.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) &&
                    !GetNotes(id).Contains(query, StringComparison.CurrentCultureIgnoreCase) &&
                    !GetTranscript(id).Contains(query, StringComparison.CurrentCultureIgnoreCase)) continue;
                meetings.Add(meeting);
            }
            return meetings.OrderByDescending(m => m.CreatedUtc).ToArray();
        }
    }

    public MeetingRecord GetMeeting(string id)
    {
        lock (gate)
        {
            var meeting = ReadJson<MeetingRecord>(Path.Combine(GetMeetingDirectory(id), "meeting.json"));
            if (meeting.Id != id) throw new InvalidDataException("The meeting metadata is inconsistent. Its files have been preserved.");
            return meeting;
        }
    }

    public MeetingRecord CreateMeeting(string title, string? projectId, string language, CaptureMode mode)
    {
        lock (gate)
        {
            title = CleanName(title, "New meeting", 160);
            ValidateProject(projectId);
            if (string.IsNullOrWhiteSpace(language)) language = "en-US";
            _ = CultureInfo.GetCultureInfo(language);
            var meeting = new MeetingRecord { Title = title, ProjectId = projectId, Language = language, CaptureMode = mode };
            Directory.CreateDirectory(GetMeetingDirectory(meeting.Id));
            SaveMeeting(meeting);
            return meeting;
        }
    }

    public void SaveMeeting(MeetingRecord meeting)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        lock (gate)
        {
            var directory = GetMeetingDirectory(meeting.Id);
            if (!Directory.Exists(directory)) throw new DirectoryNotFoundException("This meeting no longer exists.");
            ValidateProject(meeting.ProjectId);
            if (!double.IsFinite(meeting.DurationSeconds) || meeting.DurationSeconds < 0)
                throw new ArgumentOutOfRangeException(nameof(meeting), "Recording duration must be a nonnegative finite number.");
            WriteJson(Path.Combine(directory, "meeting.json"), meeting with { Title = CleanName(meeting.Title, "New meeting", 160) });
        }
    }

    public IReadOnlyList<ProjectRecord> ListProjects()
    {
        lock (gate)
        {
            var file = Path.Combine(RootPath, "projects.json");
            return File.Exists(file) || File.Exists(file + ".bak")
                ? ReadJson<List<ProjectRecord>>(file).OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToArray()
                : [];
        }
    }

    public void UpdateMeeting(string id, Func<MeetingRecord, MeetingRecord> update)
    {
        ArgumentNullException.ThrowIfNull(update);
        lock (gate)
        {
            var changed = update(GetMeeting(id));
            if (changed.Id != id) throw new InvalidOperationException("A meeting update cannot change its identifier.");
            SaveMeeting(changed);
        }
    }

    public ProjectRecord CreateProject(string name)
    {
        lock (gate)
        {
            name = CleanName(name, "", 80);
            if (name.Length == 0) throw new ArgumentException("Enter a project name.", nameof(name));
            var projects = ListProjects().ToList();
            var existing = projects.FirstOrDefault(p => p.Name.Equals(name, StringComparison.CurrentCultureIgnoreCase));
            if (existing is not null) return existing;
            var project = new ProjectRecord(Guid.NewGuid().ToString("N"), name);
            projects.Add(project);
            WriteJson(Path.Combine(RootPath, "projects.json"), projects);
            return project;
        }
    }

    public string GetMeetingDirectory(string id)
    {
        ValidateId(id);
        return Path.Combine(RootPath, "Meetings", id);
    }

    public string GetAudioPath(string id) => Path.Combine(GetMeetingDirectory(id), "audio.wav");
    public string GetNotes(string id) => ReadText(id, "notes.md");
    public string GetTranscript(string id) => ReadText(id, "transcript.txt");
    public void SaveNotes(string id, string notes) => WriteText(id, "notes.md", notes);
    public void SaveTranscript(string id, string text) => WriteText(id, "transcript.txt", text);

    public string ExportMarkdown(string id)
    {
        lock (gate)
        {
            var meeting = GetMeeting(id);
            var project = ListProjects().FirstOrDefault(p => p.Id == meeting.ProjectId)?.Name;
            var sb = new StringBuilder();
            sb.AppendLine("# " + meeting.Title.Replace("\r", " ").Replace("\n", " "));
            sb.AppendLine();
            sb.AppendLine("Date: " + meeting.CreatedUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm zzz", CultureInfo.InvariantCulture));
            sb.AppendLine("Duration: " + meeting.DisplayDuration);
            if (project is not null) sb.AppendLine("Project: " + project);
            sb.AppendLine("Language: " + meeting.Language);
            if (meeting.TranscriptProvider is not null) sb.AppendLine("Transcription: " + meeting.TranscriptProvider);
            sb.AppendLine();
            sb.AppendLine("## Notes");
            sb.AppendLine();
            sb.AppendLine(GetNotes(id));
            sb.AppendLine();
            sb.AppendLine("## Transcript");
            sb.AppendLine();
            sb.AppendLine(GetTranscript(id));
            return sb.ToString();
        }
    }

    public void DeleteAudio(string id)
    {
        lock (gate)
        {
            var meeting = GetMeeting(id);
            if (meeting.Status is "recording" or "transcribing")
                throw new InvalidOperationException("Stop the recording or transcription before deleting its audio.");
            var directory = GetMeetingDirectory(id);
            // Only audio files from this meeting. Notes, transcript and metadata remain.
            foreach (var file in Directory.EnumerateFiles(directory, "*.wav")) File.Delete(file);
            foreach (var file in Directory.EnumerateFiles(directory, "*.pcm")) File.Delete(file);
            SaveMeeting(meeting with { Status = "audio-deleted" });
        }
    }

    public AppSettings LoadSettings()
    {
        lock (gate)
        {
            var file = Path.Combine(RootPath, "settings.json");
            return File.Exists(file) || File.Exists(file + ".bak") ? ReadJson<AppSettings>(file) : new AppSettings();
        }
    }

    public void SaveSettings(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.SpeechmaticsRegion is not ("eu" or "us")) throw new ArgumentException("Choose the EU or US processing region.");
        lock (gate) WriteJson(Path.Combine(RootPath, "settings.json"), settings);
    }

    private string ReadText(string id, string filename)
    {
        lock (gate)
        {
            var file = Path.Combine(GetMeetingDirectory(id), filename);
            if (File.Exists(file)) return File.ReadAllText(file, Encoding.UTF8);
            if (File.Exists(file + ".bak")) return File.ReadAllText(file + ".bak", Encoding.UTF8);
            return "";
        }
    }

    private void WriteText(string id, string filename, string text)
    {
        lock (gate)
        {
            _ = GetMeeting(id);
            AtomicWrite(Path.Combine(GetMeetingDirectory(id), filename), text ?? "");
        }
    }

    private void ValidateProject(string? projectId)
    {
        if (projectId is null) return;
        ValidateId(projectId);
        if (!ListProjects().Any(p => p.Id == projectId)) throw new ArgumentException("Choose an existing project or create a new one.");
    }

    private static void ValidateId(string id)
    {
        if (!Guid.TryParseExact(id, "N", out _)) throw new ArgumentException("Invalid meeting or project identifier.", nameof(id));
    }

    private static string CleanName(string? value, string fallback, int maxLength)
    {
        var text = (value ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
        if (text.Length == 0) return fallback;
        return text.Length <= maxLength ? text : text[..maxLength];
    }

    private static T ReadJson<T>(string file)
    {
        Exception? failure = null;
        foreach (var candidate in new[] { file, file + ".bak" })
        {
            if (!File.Exists(candidate)) continue;
            try { return JsonSerializer.Deserialize<T>(File.ReadAllText(candidate, Encoding.UTF8), Json) ?? throw new JsonException(); }
            catch (JsonException e) { failure = e; }
        }
        throw new InvalidDataException("Hall-e could not read " + Path.GetFileName(file) + ". The original file and backup have been preserved.", failure);
    }

    private static void WriteJson<T>(string file, T value)
    {
        // Do not overwrite a good backup with a corrupt primary file during recovery.
        if (File.Exists(file))
        {
            try
            {
                using var document = JsonDocument.Parse(File.ReadAllText(file, Encoding.UTF8));
                AtomicWrite(file + ".bak", document.RootElement.GetRawText(), backup: false);
            }
            catch (JsonException) { }
        }
        AtomicWrite(file, JsonSerializer.Serialize(value, Json), backup: false);
    }

    private static void AtomicWrite(string file, string text, bool backup = true)
    {
        var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                var bytes = Encoding.UTF8.GetBytes(text);
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            if (backup && File.Exists(file))
                AtomicWrite(file + ".bak", File.ReadAllText(file, Encoding.UTF8), backup: false);
            File.Move(temporary, file, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
