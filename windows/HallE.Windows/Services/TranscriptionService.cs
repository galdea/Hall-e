using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Speech.Recognition;
using System.Text;
using System.Text.Json;
using HallE.Core;

namespace HallE.Windows.Services;

public sealed class TranscriptionService
{
    private const string DeepgramModel = "nova-3";
    private const string SpeechmaticsModel = "melia-1";
    private const string SpeechmaticsAmbiguousStatus = "speechmatics-submission-ambiguous";
    private static readonly TimeSpan CredentialValidationTimeout = TimeSpan.FromSeconds(25);
    private static readonly TimeSpan CloudOperationTimeout = TimeSpan.FromHours(1);

    private static readonly HttpClient Http = CreateHttpClient();

    private readonly LibraryStore _library;
    private readonly CredentialStore _credentials;

    public TranscriptionService(LibraryStore library, CredentialStore credentials)
    {
        _library = library ?? throw new ArgumentNullException(nameof(library));
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
    }

    public IReadOnlyList<string> GetLocalLanguages()
    {
        try
        {
            return SpeechRecognitionEngine.InstalledRecognizers()
                .Select(recognizer => recognizer.Culture.Name)
                .Where(language => !string.IsNullOrWhiteSpace(language))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(language => language, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException(
                "Windows Speech Recognition could not enumerate installed offline speech languages.",
                exception);
        }
    }

    public async Task ValidateKeyAsync(
        TranscriptionProvider provider,
        string key,
        string region,
        CancellationToken cancellationToken = default)
    {
        if (provider == TranscriptionProvider.Local)
        {
            throw new ArgumentException("Local Windows speech recognition does not use an API key.", nameof(provider));
        }

        var normalizedKey = CredentialStore.NormalizeKey(key);
        var endpoint = provider switch
        {
            TranscriptionProvider.Deepgram => new Uri("https://api.deepgram.com/v1/auth/token"),
            TranscriptionProvider.Speechmatics => new Uri($"{SpeechmaticsEndpoint(NormalizeSpeechmaticsRegion(region))}?limit=1"),
            _ => throw new ArgumentOutOfRangeException(nameof(provider)),
        };

        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Authorization = provider == TranscriptionProvider.Deepgram
            ? new AuthenticationHeaderValue("Token", normalizedKey)
            : new AuthenticationHeaderValue("Bearer", normalizedKey);

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CredentialValidationTimeout);
        HttpResponseMessage response;
        try
        {
            response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            throw new InvalidOperationException($"Could not connect to {ProviderName(provider)} to verify the API key.", exception);
        }

        using (response)
        {
            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw new InvalidOperationException(
                    $"{ProviderName(provider)} rejected the credential check (HTTP {(int)response.StatusCode}). The saved key was not changed.");
            }

            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            JsonDocument document;
            try
            {
                document = await JsonDocument.ParseAsync(stream, cancellationToken: timeout.Token).ConfigureAwait(false);
            }
            catch (JsonException exception)
            {
                throw new InvalidOperationException($"{ProviderName(provider)} returned an unexpected credential-check response.", exception);
            }

            using (document)
            {
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object
                    || !root.EnumerateObject().Any()
                    || root.TryGetProperty("error", out _)
                    || root.TryGetProperty("err_code", out _))
                {
                    throw new InvalidOperationException($"{ProviderName(provider)} returned an unexpected credential-check response.");
                }

                if (provider == TranscriptionProvider.Speechmatics
                    && (!root.TryGetProperty("jobs", out var jobs) || jobs.ValueKind != JsonValueKind.Array))
                {
                    throw new InvalidOperationException("Speechmatics returned an unexpected credential-check response.");
                }
            }
        }
    }

    public Task<TranscriptionResult> TranscribeAsync(
        MeetingRecord meeting,
        AppSettings settings,
        IProgress<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(meeting);
        ArgumentNullException.ThrowIfNull(settings);
        cancellationToken.ThrowIfCancellationRequested();

        var audioPath = _library.GetAudioPath(meeting.Id);
        if (!File.Exists(audioPath))
        {
            throw new FileNotFoundException("The meeting audio.wav file is missing. Recording audio is never recreated from cloud state.", audioPath);
        }

        return settings.Provider switch
        {
            TranscriptionProvider.Local => TranscribeLocalAsync(meeting, audioPath, progress, cancellationToken),
            TranscriptionProvider.Deepgram => TranscribeDeepgramAsync(audioPath, settings, progress, cancellationToken),
            TranscriptionProvider.Speechmatics => TranscribeSpeechmaticsAsync(meeting, audioPath, settings, progress, cancellationToken),
            _ => throw new ArgumentOutOfRangeException(nameof(settings.Provider)),
        };
    }

    private async Task<TranscriptionResult> TranscribeLocalAsync(
        MeetingRecord meeting,
        string audioPath,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var requestedLanguage = string.IsNullOrWhiteSpace(meeting.Language) ? "en-US" : meeting.Language;
        RecognizerInfo? recognizer;
        try
        {
            recognizer = SpeechRecognitionEngine.InstalledRecognizers()
                .FirstOrDefault(item => string.Equals(item.Culture.Name, requestedLanguage, StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception exception)
        {
            throw new InvalidOperationException("Windows Speech Recognition is unavailable on this computer.", exception);
        }

        if (recognizer is null)
        {
            var installed = GetLocalLanguages();
            var suffix = installed.Count == 0
                ? "No offline speech recognizers are installed. Install a Windows Speech language pack first."
                : $"Installed offline languages: {string.Join(", ", installed)}.";
            throw new InvalidOperationException(
                $"No installed Windows offline speech recognizer matches {requestedLanguage}. {suffix}");
        }

        progress?.Report($"Recognizing locally with Windows Speech ({recognizer.Culture.Name})…");
        return await RecognizeSapiFileAsync(recognizer, audioPath, progress, cancellationToken).ConfigureAwait(false);
    }

    private static async Task<TranscriptionResult> RecognizeSapiFileAsync(
        RecognizerInfo recognizer,
        string audioPath,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        using var engine = new SpeechRecognitionEngine(recognizer.Id);
        var text = new StringBuilder();
        var gate = new object();
        var completion = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);

        engine.SpeechRecognized += (_, args) =>
        {
            var recognized = args.Result?.Text?.Trim();
            if (string.IsNullOrEmpty(recognized))
            {
                return;
            }

            lock (gate)
            {
                if (text.Length > 0)
                {
                    text.AppendLine();
                }
                text.Append(recognized);
            }
            progress?.Report("Recognizing locally…");
        };
        engine.RecognizeCompleted += (_, args) =>
        {
            if (args.Error is not null)
            {
                completion.TrySetException(args.Error);
            }
            else if (args.Cancelled)
            {
                completion.TrySetCanceled(cancellationToken);
            }
            else
            {
                completion.TrySetResult(null);
            }
        };

        engine.SetInputToWaveFile(audioPath);
        engine.LoadGrammar(new DictationGrammar());
        cancellationToken.ThrowIfCancellationRequested();
        engine.RecognizeAsync(RecognizeMode.Multiple);
        using var registration = cancellationToken.Register(() =>
        {
            try
            {
                engine.RecognizeAsyncCancel();
            }
            catch
            {
                completion.TrySetCanceled(cancellationToken);
            }
        });

        cancellationToken.ThrowIfCancellationRequested();
        await completion.Task.ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        string result;
        lock (gate)
        {
            result = text.ToString().Trim();
        }
        return new TranscriptionResult(result, "local:sapi");
    }

    private async Task<TranscriptionResult> TranscribeDeepgramAsync(
        string audioPath,
        AppSettings settings,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        if (!settings.DeepgramConsent)
        {
            throw new InvalidOperationException("Deepgram audio upload requires explicit cloud audio consent in Settings.");
        }

        var key = _credentials.GetKey(TranscriptionProvider.Deepgram);
        if (string.IsNullOrWhiteSpace(key))
        {
            throw new InvalidOperationException("Add and test a Deepgram API key in Settings before uploading audio.");
        }

        var endpoint = new Uri(
            $"https://api.deepgram.com/v1/listen?model={DeepgramModel}&language=multi&smart_format=true&utterances=true&diarize_model=v2&mip_opt_out=true");
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Token", key);
        await using var audio = new FileStream(audioPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        using var content = new StreamContent(audio, 1024 * 1024);
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        request.Content = content;

        progress?.Report("Uploading audio to Deepgram…");
        using var response = await SendPaidUploadOnceAsync(
            request,
            "Deepgram may have received the audio, but Hall-e lost the response. Review before retrying to avoid duplicate billing.",
            cancellationToken).ConfigureAwait(false);
        var body = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
        EnsureCloudSuccess(response, body, "Deepgram");

        progress?.Report("Formatting Deepgram transcript…");
        return new TranscriptionResult(ParseDeepgram(body), $"deepgram:{DeepgramModel}");
    }

    private async Task<TranscriptionResult> TranscribeSpeechmaticsAsync(
        MeetingRecord meeting,
        string audioPath,
        AppSettings settings,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        if (!settings.SpeechmaticsConsent)
        {
            throw new InvalidOperationException("Speechmatics audio upload requires explicit cloud audio consent in Settings.");
        }
        if (!settings.SpeechmaticsTrainingDisabled)
        {
            throw new InvalidOperationException("Confirm that Speechmatics Model Training is disabled before uploading meeting audio.");
        }

        var key = _credentials.GetKey(TranscriptionProvider.Speechmatics);
        if (string.IsNullOrWhiteSpace(key))
        {
            throw new InvalidOperationException("Add and test a Speechmatics API key in Settings before uploading audio.");
        }

        // Re-read metadata so a stale MeetingRecord from the UI can never cause
        // a duplicate paid submission after a job ID has already been persisted.
        var persisted = _library.GetMeeting(meeting.Id);
        if (string.IsNullOrWhiteSpace(persisted.RemoteJobId)
            && (persisted.SpeechmaticsSubmissionUncertain || string.Equals(persisted.Status, SpeechmaticsAmbiguousStatus, StringComparison.Ordinal)))
        {
            throw new InvalidOperationException(
                "The previous Speechmatics submission ended ambiguously and may already have created a paid job. Hall-e will not upload this audio again automatically.");
        }

        string region;
        string jobId;
        if (!string.IsNullOrWhiteSpace(persisted.RemoteJobId))
        {
            if (string.IsNullOrWhiteSpace(persisted.RemoteJobRegion))
            {
                throw new InvalidOperationException("A saved Speechmatics job is missing its processing region, so Hall-e cannot resume it safely.");
            }

            region = NormalizeSpeechmaticsRegion(persisted.RemoteJobRegion);
            jobId = persisted.RemoteJobId;
            progress?.Report($"Resuming Speechmatics job {jobId}…");
        }
        else
        {
            region = NormalizeSpeechmaticsRegion(settings.SpeechmaticsRegion);
            jobId = await SubmitSpeechmaticsJobAsync(persisted, audioPath, key, region, progress, cancellationToken).ConfigureAwait(false);
        }

        await WaitForSpeechmaticsJobAsync(jobId, key, region, progress, cancellationToken).ConfigureAwait(false);
        var transcriptBytes = await GetSpeechmaticsTranscriptAsync(jobId, key, region, cancellationToken).ConfigureAwait(false);
        progress?.Report("Formatting Speechmatics transcript…");
        return new TranscriptionResult(ParseSpeechmatics(transcriptBytes), $"speechmatics:{SpeechmaticsModel}");
    }

    private async Task<string> SubmitSpeechmaticsJobAsync(
        MeetingRecord meeting,
        string audioPath,
        string key,
        string region,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var digest = await ComputeSha256Async(audioPath, cancellationToken).ConfigureAwait(false);
        var info = new FileInfo(audioPath);
        var reference = $"speechmatics|{meeting.Id}|{digest}|{info.Length}|{SpeechmaticsModel}|multi|speaker|prefer-current";
        var config = JsonSerializer.Serialize(new
        {
            type = "transcription",
            transcription_config = new
            {
                model = SpeechmaticsModel,
                language = "multi",
                diarization = "speaker",
                speaker_diarization_config = new { prefer_current_speaker = true },
            },
            tracking = new { reference },
        });

        var endpoint = new Uri($"{SpeechmaticsEndpoint(region)}?wait=0&format=json-v2");
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var multipart = new MultipartFormDataContent();
        using var configContent = new StringContent(config, Encoding.UTF8, "application/json");
        await using var audio = new FileStream(audioPath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        using var audioContent = new StreamContent(audio, 1024 * 1024);
        audioContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        multipart.Add(configContent, "config");
        multipart.Add(audioContent, "data_file", Path.GetFileName(audioPath));
        request.Content = multipart;

        progress?.Report($"Uploading audio to Speechmatics {region.ToUpperInvariant()}…");
        cancellationToken.ThrowIfCancellationRequested();
        // Durable before the first byte leaves the computer. Cancellation, a lost
        // response, or a process crash must never turn into an implicit new job.
        _library.UpdateMeeting(meeting.Id, latest => latest with
        {
            SpeechmaticsSubmissionUncertain = true,
            RemoteJobRegion = region
        });
        HttpResponseMessage response;
        try
        {
            response = await SendPaidUploadOnceAsync(
                request,
                "Speechmatics may have created a paid job, but Hall-e did not receive its ID. The audio will not be uploaded again automatically.",
                cancellationToken).ConfigureAwait(false);
        }
        catch (AmbiguousSubmissionException exception)
        {
            PersistSpeechmaticsAmbiguity(meeting.Id, region, exception.Message);
            throw new InvalidOperationException(exception.Message, exception);
        }

        using (response)
        {
            var body = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
            if ((int)response.StatusCode >= 500)
            {
                var message = $"Speechmatics returned HTTP {(int)response.StatusCode} without a job ID. Hall-e cannot safely repeat this upload automatically.";
                PersistSpeechmaticsAmbiguity(meeting.Id, region, message);
                throw new InvalidOperationException(message);
            }
            if (response.StatusCode != HttpStatusCode.Created)
            {
                if ((int)response.StatusCode is 400 or 401 or 403 or 404 or 413 or 415 or 422 or 429)
                    _library.UpdateMeeting(meeting.Id, latest => latest with { SpeechmaticsSubmissionUncertain = false });
                EnsureCloudSuccess(response, body, "Speechmatics");
                throw new InvalidOperationException($"Speechmatics returned HTTP {(int)response.StatusCode}; expected a created job response.");
            }

            string? jobId = null;
            try
            {
                using var document = JsonDocument.Parse(body);
                if (document.RootElement.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.String)
                {
                    jobId = idElement.GetString();
                }
            }
            catch (JsonException)
            {
                // A 201 without a readable ID is ambiguous: the paid job may exist.
            }

            if (string.IsNullOrWhiteSpace(jobId))
            {
                var message = "Speechmatics accepted the upload without a readable job ID. Hall-e will not upload it again automatically.";
                PersistSpeechmaticsAmbiguity(meeting.Id, region, message);
                throw new InvalidOperationException(message);
            }

            _library.UpdateMeeting(meeting.Id, latest => latest with
            {
                RemoteJobId = jobId,
                RemoteJobRegion = region,
                SpeechmaticsSubmissionUncertain = false,
            });
            progress?.Report($"Speechmatics job {jobId} created; job metadata saved locally.");
            return jobId;
        }
    }

    private async Task WaitForSpeechmaticsJobAsync(
        string jobId,
        string key,
        string region,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + CloudOperationTimeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var endpoint = new Uri($"{SpeechmaticsEndpoint(region)}{Uri.EscapeDataString(jobId)}?wait=60");
            using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            using var response = await SendSafeCloudRequestAsync(request, "Speechmatics job retrieval", cancellationToken).ConfigureAwait(false);
            var body = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
            EnsureCloudSuccess(response, body, "Speechmatics");

            using var document = ParseJson(body, "Speechmatics returned unreadable job status.");
            if (!document.RootElement.TryGetProperty("job", out var job)
                || !job.TryGetProperty("status", out var statusElement)
                || statusElement.ValueKind != JsonValueKind.String)
            {
                throw new InvalidOperationException("Speechmatics returned unreadable job status.");
            }

            var status = statusElement.GetString() ?? string.Empty;
            progress?.Report($"Speechmatics job status: {status}");
            if (status == "done")
            {
                return;
            }
            if (status is "rejected" or "deleted")
            {
                throw new InvalidOperationException(ExtractSpeechmaticsJobError(job));
            }
            await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken).ConfigureAwait(false);
        }

        throw new InvalidOperationException("Speechmatics is still processing this recording. Retry later to resume the saved job without uploading again.");
    }

    private static async Task<byte[]> GetSpeechmaticsTranscriptAsync(
        string jobId,
        string key,
        string region,
        CancellationToken cancellationToken)
    {
        var endpoint = new Uri($"{SpeechmaticsEndpoint(region)}{Uri.EscapeDataString(jobId)}/transcript?wait=60&format=json-v2");
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await SendSafeCloudRequestAsync(request, "Speechmatics transcript retrieval", cancellationToken).ConfigureAwait(false);
        var body = await ReadResponseBytesAsync(response, cancellationToken).ConfigureAwait(false);
        EnsureCloudSuccess(response, body, "Speechmatics");
        return body;
    }

    private void PersistSpeechmaticsAmbiguity(string meetingId, string region, string message)
    {
        _library.UpdateMeeting(meetingId, latest => latest with
        {
            RemoteJobRegion = region,
            SpeechmaticsSubmissionUncertain = true,
            Status = SpeechmaticsAmbiguousStatus,
            TranscriptionError = message,
        });
    }

    private static async Task<HttpResponseMessage> SendPaidUploadOnceAsync(
        HttpRequestMessage request,
        string ambiguousMessage,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CloudOperationTimeout);
        try
        {
            return await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            throw new AmbiguousSubmissionException(ambiguousMessage, exception);
        }
    }

    private static async Task<HttpResponseMessage> SendSafeCloudRequestAsync(
        HttpRequestMessage request,
        string operation,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(CloudOperationTimeout);
        try
        {
            return await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception) when (exception is HttpRequestException or OperationCanceledException)
        {
            throw new InvalidOperationException($"{operation} was interrupted and can be resumed without re-uploading audio.", exception);
        }
    }

    private static async Task<byte[]> ReadResponseBytesAsync(HttpResponseMessage response, CancellationToken cancellationToken)
        => await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);

    private static void EnsureCloudSuccess(HttpResponseMessage response, byte[] body, string provider)
    {
        if (response.IsSuccessStatusCode)
        {
            return;
        }

        var status = (int)response.StatusCode;
        var detail = TryReadCloudError(body);
        if (status is 401 or 403)
        {
            throw new InvalidOperationException($"{provider} rejected the saved API key (HTTP {status}). Test the key again in Settings.");
        }
        if (status == 408 || status == 429 || status >= 500)
        {
            throw new InvalidOperationException($"{provider} temporarily rejected the request (HTTP {status}). {detail}".Trim());
        }

        throw new InvalidOperationException($"{provider} rejected the transcription request (HTTP {status}). {detail}".Trim());
    }

    private static string ParseDeepgram(byte[] body)
    {
        using var document = ParseJson(body, "Deepgram returned an unreadable transcription response.");
        var root = document.RootElement;
        if (!root.TryGetProperty("results", out var results)
            || !results.TryGetProperty("channels", out var channels)
            || channels.ValueKind != JsonValueKind.Array
            || channels.GetArrayLength() == 0
            || !channels[0].TryGetProperty("alternatives", out var alternatives)
            || alternatives.ValueKind != JsonValueKind.Array
            || alternatives.GetArrayLength() == 0)
        {
            throw new InvalidOperationException("Deepgram returned no transcript alternative.");
        }

        var alternative = alternatives[0];
        var transcript = alternative.TryGetProperty("transcript", out var transcriptElement)
            ? transcriptElement.GetString()?.Trim() ?? string.Empty
            : string.Empty;

        if (transcript.Length == 0)
        {
            return string.Empty;
        }

        if (!alternative.TryGetProperty("words", out var words) || words.ValueKind != JsonValueKind.Array || words.GetArrayLength() == 0)
        {
            throw new InvalidOperationException("Deepgram returned speech without complete diarization.");
        }
        foreach (var word in words.EnumerateArray())
        {
            if (!word.TryGetProperty("speaker", out var speaker) || speaker.ValueKind != JsonValueKind.Number)
            {
                throw new InvalidOperationException("Deepgram returned speech without complete diarization.");
            }
        }

        if (!results.TryGetProperty("utterances", out var utterances)
            || utterances.ValueKind != JsonValueKind.Array
            || utterances.GetArrayLength() == 0)
        {
            throw new InvalidOperationException("Deepgram returned speech without complete diarization.");
        }

        var lines = new List<string>();
        foreach (var utterance in utterances.EnumerateArray())
        {
            var text = utterance.TryGetProperty("transcript", out var textElement)
                ? textElement.GetString()?.Trim()
                : null;
            if (string.IsNullOrWhiteSpace(text))
            {
                continue;
            }
            if (!utterance.TryGetProperty("speaker", out var speakerElement) || !speakerElement.TryGetInt32(out var speaker))
            {
                throw new InvalidOperationException("Deepgram returned speech without complete diarization.");
            }
            lines.Add($"Speaker {speaker + 1}: {text}");
        }

        if (lines.Count == 0)
        {
            throw new InvalidOperationException("Deepgram returned speech without complete diarization.");
        }
        return string.Join(Environment.NewLine, lines);
    }

    private static string ParseSpeechmatics(byte[] body)
    {
        using var document = ParseJson(body, "Speechmatics returned an unreadable transcript.");
        if (!document.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("Speechmatics returned an unreadable transcript.");
        }

        var speakerNumbers = new Dictionary<string, int>(StringComparer.Ordinal);
        var lines = new List<string>();
        var currentSpeaker = string.Empty;
        var current = new StringBuilder();
        var sawSpeech = false;

        void Flush()
        {
            var value = current.ToString().Trim();
            if (value.Length > 0)
            {
                var number = speakerNumbers[currentSpeaker];
                lines.Add($"Speaker {number}: {value}");
            }
            current.Clear();
        }

        foreach (var result in results.EnumerateArray())
        {
            var type = result.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
            if (type is not ("word" or "punctuation"))
            {
                continue;
            }
            if (!result.TryGetProperty("alternatives", out var alternatives)
                || alternatives.ValueKind != JsonValueKind.Array
                || alternatives.GetArrayLength() == 0)
            {
                continue;
            }

            var alternative = alternatives[0];
            var content = alternative.TryGetProperty("content", out var contentElement)
                ? contentElement.GetString() ?? string.Empty
                : string.Empty;
            if (content.Length == 0)
            {
                continue;
            }

            if (type == "word")
            {
                sawSpeech = true;
                var speaker = alternative.TryGetProperty("speaker", out var speakerElement)
                    ? speakerElement.GetString()
                    : null;
                if (string.IsNullOrWhiteSpace(speaker) || speaker == "UU")
                {
                    throw new InvalidOperationException("Speechmatics returned speech without complete speaker diarization.");
                }

                if (!speakerNumbers.ContainsKey(speaker))
                {
                    speakerNumbers[speaker] = speakerNumbers.Count + 1;
                }
                if (current.Length > 0 && !string.Equals(currentSpeaker, speaker, StringComparison.Ordinal))
                {
                    Flush();
                }
                currentSpeaker = speaker;
                if (current.Length > 0)
                {
                    current.Append(' ');
                }
                current.Append(content);
            }
            else if (current.Length > 0)
            {
                var attachesToPrevious = result.TryGetProperty("attaches_to", out var attaches)
                    && string.Equals(attaches.GetString(), "previous", StringComparison.Ordinal);
                if (!attachesToPrevious)
                {
                    current.Append(' ');
                }
                current.Append(content);
            }

            if (result.TryGetProperty("is_eos", out var eos) && eos.ValueKind == JsonValueKind.True && current.Length > 0)
            {
                Flush();
            }
        }

        if (current.Length > 0)
        {
            Flush();
        }
        if (!sawSpeech)
        {
            return string.Empty;
        }
        if (lines.Count == 0)
        {
            throw new InvalidOperationException("Speechmatics returned speech without complete speaker diarization.");
        }
        return string.Join(Environment.NewLine, lines);
    }

    private static JsonDocument ParseJson(byte[] body, string message)
    {
        try
        {
            return JsonDocument.Parse(body);
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(message, exception);
        }
    }

    private static string ExtractSpeechmaticsJobError(JsonElement job)
    {
        if (job.TryGetProperty("errors", out var errors) && errors.ValueKind == JsonValueKind.Array)
        {
            var messages = errors.EnumerateArray()
                .Select(error => error.TryGetProperty("message", out var message) ? message.GetString() : null)
                .Where(message => !string.IsNullOrWhiteSpace(message));
            var combined = string.Join("; ", messages!);
            if (!string.IsNullOrWhiteSpace(combined))
            {
                return combined;
            }
        }
        return "Speechmatics could not process this recording.";
    }

    private static string TryReadCloudError(byte[] body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            foreach (var property in new[] { "err_msg", "message", "error", "detail" })
            {
                if (document.RootElement.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String)
                {
                    return value.GetString() ?? string.Empty;
                }
            }
        }
        catch (JsonException)
        {
        }
        return string.Empty;
    }

    private static async Task<string> ComputeSha256Async(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
        using var sha256 = SHA256.Create();
        var hash = await sha256.ComputeHashAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static string NormalizeSpeechmaticsRegion(string region)
    {
        var normalized = (region ?? string.Empty).Trim().ToLowerInvariant();
        return normalized switch
        {
            "us" or "us1" => "us1",
            "eu" or "eu1" => "eu1",
            _ => throw new InvalidOperationException("Choose a supported Speechmatics processing region: US1 or EU1."),
        };
    }

    private static string SpeechmaticsEndpoint(string region)
        => $"https://{region}.asr.api.speechmatics.com/v2/jobs/";

    private static string ProviderName(TranscriptionProvider provider)
        => provider switch
        {
            TranscriptionProvider.Deepgram => "Deepgram",
            TranscriptionProvider.Speechmatics => "Speechmatics",
            _ => "Cloud provider",
        };

    private static HttpClient CreateHttpClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        };
        return new HttpClient(handler)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    private sealed class AmbiguousSubmissionException : Exception
    {
        public AmbiguousSubmissionException(string message, Exception innerException)
            : base(message, innerException)
        {
        }
    }
}
