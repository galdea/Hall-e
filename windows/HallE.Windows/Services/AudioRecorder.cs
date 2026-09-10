using System.Diagnostics;
using System.Text.Json;
using HallE.Core;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace HallE.Windows.Services;

public sealed class AudioRecorder : IDisposable
{
    private const int OutputSampleRate = 48_000;
    private const int MicrophoneBits = 16;
    private const int MicrophoneChannels = 1;
    private const int GapToleranceMilliseconds = 100;

    private readonly object _gate = new();
    private WaveInEvent? _microphone;
    private WasapiLoopbackCapture? _loopback;
    private TimedWaveSink? _microphoneSink;
    private TimedWaveSink? _loopbackSink;
    private TaskCompletionSource<object?>? _microphoneStopped;
    private TaskCompletionSource<object?>? _loopbackStopped;
    private Stopwatch? _clock;
    private RecordingManifest? _manifest;
    private string? _manifestPath;
    private bool _sessionActive;
    private bool _stopRequested;
    private bool _disposed;
    private bool _microphoneStarted;
    private bool _loopbackStarted;
    private string? _captureWarning;

    public bool IsRecording
    {
        get
        {
            lock (_gate)
            {
                return _sessionActive && !_stopRequested && _captureWarning is null;
            }
        }
    }

    public event Action<float>? LevelChanged;
    public event Action<string>? Warning;

    public IReadOnlyList<AudioDevice> GetMicrophones()
    {
        ThrowIfDisposed();
        var devices = new List<AudioDevice>();
        for (var index = 0; index < WaveIn.DeviceCount; index++)
        {
            var capabilities = WaveIn.GetCapabilities(index);
            devices.Add(new AudioDevice($"wavein:{index}", capabilities.ProductName));
        }

        return devices;
    }

    public async Task StartAsync(string wavPath, CaptureMode mode, string? microphoneId = null)
    {
        ThrowIfDisposed();
        if (string.IsNullOrWhiteSpace(wavPath))
        {
            throw new ArgumentException("A WAV output path is required.", nameof(wavPath));
        }

        var fullPath = Path.GetFullPath(wavPath);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("The recording path has no parent directory.");
        Directory.CreateDirectory(directory);

        lock (_gate)
        {
            if (_sessionActive)
            {
                throw new InvalidOperationException("A recording is already active in this recorder.");
            }

            _sessionActive = true;
            _stopRequested = false;
            _captureWarning = null;
        }

        var microphonePath = PartialPath(fullPath, "mic");
        var systemPath = mode == CaptureMode.MicrophoneAndSystem ? PartialPath(fullPath, "system") : null;
        var manifestPath = ManifestPath(fullPath);

        try
        {
            var microphoneIndex = ResolveMicrophoneIndex(microphoneId);
            var clock = new Stopwatch();
            var microphone = new WaveInEvent
            {
                DeviceNumber = microphoneIndex,
                WaveFormat = new WaveFormat(OutputSampleRate, MicrophoneBits, MicrophoneChannels),
                BufferMilliseconds = 50,
                NumberOfBuffers = 4,
            };
            _microphone = microphone;
            var microphoneSink = new TimedWaveSink(microphonePath, microphone.WaveFormat, clock);
            _microphoneSink = microphoneSink;
            var microphoneStopped = NewStoppedSource();

            WasapiLoopbackCapture? loopback = null;
            TimedWaveSink? loopbackSink = null;
            TaskCompletionSource<object?>? loopbackStopped = null;
            if (mode == CaptureMode.MicrophoneAndSystem)
            {
                loopback = new WasapiLoopbackCapture();
                _loopback = loopback;
                loopbackSink = new TimedWaveSink(systemPath!, loopback.WaveFormat, clock);
                _loopbackSink = loopbackSink;
                loopbackStopped = NewStoppedSource();
            }

            var manifest = new RecordingManifest(
                Path.GetFileName(fullPath),
                Path.GetFileName(microphonePath),
                systemPath is null ? null : Path.GetFileName(systemPath),
                mode,
                DateTimeOffset.UtcNow);
            WriteManifest(manifestPath, manifest);

            lock (_gate)
            {
                _microphone = microphone;
                _loopback = loopback;
                _microphoneSink = microphoneSink;
                _loopbackSink = loopbackSink;
                _microphoneStopped = microphoneStopped;
                _loopbackStopped = loopbackStopped;
                _clock = clock;
                _manifest = manifest;
                _manifestPath = manifestPath;
            }

            microphone.DataAvailable += OnMicrophoneData;
            microphone.RecordingStopped += OnMicrophoneStopped;
            if (loopback is not null)
            {
                loopback.DataAvailable += OnLoopbackData;
                loopback.RecordingStopped += OnLoopbackStopped;
            }

            clock.Start();
            microphone.StartRecording();
            _microphoneStarted = true;
            if (loopback is not null)
            {
                try
                {
                    loopback.StartRecording();
                    _loopbackStarted = true;
                }
                catch
                {
                    // The loopback capture never started, so no native stopped
                    // callback will arrive for it during rollback.
                    loopbackStopped!.TrySetResult(null);
                    microphone.StopRecording();
                    await microphoneStopped.Task.ConfigureAwait(false);
                    throw;
                }

                Warning?.Invoke("Computer audio capture is enabled and records all audio playing through the selected Windows output device.");
            }
        }
        catch (Exception exception)
        {
            var message = $"Recording could not start: {exception.Message}";
            Warning?.Invoke(message);
            try
            {
                await AbortStartAsync().ConfigureAwait(false);
            }
            catch
            {
                // Preserve the original start failure. AbortStartAsync already
                // disposes every capture object it can reach.
            }
            throw new InvalidOperationException(message, exception);
        }
    }

    public async Task<CaptureResult> StopAsync()
    {
        ThrowIfDisposed();

        WaveInEvent? microphone;
        WasapiLoopbackCapture? loopback;
        Task microphoneStopped;
        Task? loopbackStopped;
        Stopwatch clock;
        RecordingManifest manifest;
        string manifestPath;
        string? captureWarning;

        lock (_gate)
        {
            if (!_sessionActive || _manifest is null || _manifestPath is null || _clock is null || _microphoneStopped is null)
            {
                throw new InvalidOperationException("No recording is active.");
            }

            if (_stopRequested)
            {
                throw new InvalidOperationException("This recording is already stopping.");
            }

            _stopRequested = true;
            microphone = _microphone;
            loopback = _loopback;
            microphoneStopped = _microphoneStopped.Task;
            loopbackStopped = _loopbackStopped?.Task;
            clock = _clock;
            manifest = _manifest;
            manifestPath = _manifestPath;
            captureWarning = _captureWarning;
        }

        RequestStop(microphone, _microphoneStopped);
        RequestStop(loopback, _loopbackStopped);

        try
        {
            if (loopbackStopped is not null)
            {
                await Task.WhenAll(microphoneStopped, loopbackStopped).ConfigureAwait(false);
            }
            else
            {
                await microphoneStopped.ConfigureAwait(false);
            }
        }
        catch (Exception exception)
        {
            var message = $"Windows reported an error while stopping audio capture: {exception.GetBaseException().Message}";
            captureWarning ??= message;
            Warning?.Invoke(message);
        }

        clock.Stop();
        var duration = Math.Max(0, clock.Elapsed.TotalSeconds);

        DisposeCaptureObjects();

        var directory = Path.GetDirectoryName(manifestPath)!;
        var targetPath = SafeCombine(directory, manifest.TargetFileName);
        var microphonePath = SafeCombine(directory, manifest.MicrophoneFileName);
        var systemPath = manifest.SystemFileName is null ? null : SafeCombine(directory, manifest.SystemFileName);

        try
        {
            await Task.Run(() => FinalizeTracks(targetPath, microphonePath, systemPath)).ConfigureAwait(false);
            TryDelete(microphonePath);
            if (systemPath is not null)
            {
                TryDelete(systemPath);
            }
            TryDelete(manifestPath);
        }
        catch (Exception exception)
        {
            ResetSessionState();
            var message = $"Recording stopped, but the final WAV could not be created. The recorded source WAV files were preserved for recovery. {exception.Message}";
            Warning?.Invoke(message);
            throw new InvalidOperationException(message, exception);
        }

        lock (_gate)
        {
            captureWarning ??= _captureWarning;
        }
        ResetSessionState();
        return new CaptureResult(duration, captureWarning);
    }

    public static void RecoverInterruptedAudio(string directory)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            return;
        }

        foreach (var manifestPath in Directory.EnumerateFiles(directory, ".*.halle-recording.json", SearchOption.TopDirectoryOnly))
        {
            RecordingManifest? manifest;
            try
            {
                manifest = JsonSerializer.Deserialize<RecordingManifest>(File.ReadAllText(manifestPath));
            }
            catch
            {
                continue;
            }

            if (manifest is null)
            {
                continue;
            }

            try
            {
                var targetPath = SafeCombine(directory, manifest.TargetFileName);
                var microphonePath = SafeCombine(directory, manifest.MicrophoneFileName);
                var systemPath = manifest.SystemFileName is null ? null : SafeCombine(directory, manifest.SystemFileName);

                var hasMicrophone = RepairWaveHeader(microphonePath);
                var hasSystem = systemPath is not null && RepairWaveHeader(systemPath);
                if (!hasMicrophone && !hasSystem)
                {
                    continue;
                }

                FinalizeTracks(targetPath, hasMicrophone ? microphonePath : null, hasSystem ? systemPath : null);
                if (hasMicrophone)
                {
                    TryDelete(microphonePath);
                }
                if (hasSystem && systemPath is not null)
                {
                    TryDelete(systemPath);
                }
                TryDelete(manifestPath);
            }
            catch
            {
                // Recovery is intentionally best-effort. Source WAVs and the
                // manifest remain in place so a later attempt can recover them.
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (_sessionActive)
        {
            try
            {
                StopAsync().GetAwaiter().GetResult();
            }
            catch
            {
                DisposeCaptureObjects();
                ResetSessionState();
            }
        }

        _disposed = true;
    }

    private void OnMicrophoneData(object? sender, WaveInEventArgs args)
    {
        try
        {
            _microphoneSink?.Write(args.Buffer, args.BytesRecorded);
            LevelChanged?.Invoke(CalculateLevel(args.Buffer, args.BytesRecorded));
        }
        catch (Exception exception)
        {
            HandleCaptureFailure("Microphone recording failed", exception, stopMicrophone: true, stopLoopback: true);
        }
    }

    private void OnLoopbackData(object? sender, WaveInEventArgs args)
    {
        try
        {
            _loopbackSink?.Write(args.Buffer, args.BytesRecorded);
        }
        catch (Exception exception)
        {
            HandleCaptureFailure("Computer audio recording failed", exception, stopMicrophone: true, stopLoopback: true);
        }
    }

    private void OnMicrophoneStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            HandleCaptureFailure("Microphone capture stopped unexpectedly", args.Exception, stopMicrophone: false, stopLoopback: true);
        }
        _microphoneStopped?.TrySetResult(null);
    }

    private void OnLoopbackStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            HandleCaptureFailure("Computer audio capture stopped unexpectedly", args.Exception, stopMicrophone: true, stopLoopback: false);
        }
        _loopbackStopped?.TrySetResult(null);
    }

    private void HandleCaptureFailure(string prefix, Exception exception, bool stopMicrophone, bool stopLoopback)
    {
        var message = $"{prefix}: {exception.Message}";
        var first = false;
        lock (_gate)
        {
            if (_captureWarning is null)
            {
                _captureWarning = message;
                first = true;
            }
        }

        if (first)
        {
            Warning?.Invoke(message);
        }

        if (stopMicrophone || stopLoopback)
        {
            ThreadPool.QueueUserWorkItem(_ =>
            {
                if (stopMicrophone)
                {
                    RequestStop(_microphone, _microphoneStopped);
                }
                if (stopLoopback)
                {
                    RequestStop(_loopback, _loopbackStopped);
                }
            });
        }
    }

    private async Task AbortStartAsync()
    {
        WaveInEvent? microphone;
        WasapiLoopbackCapture? loopback;
        Task? microphoneStopped;
        Task? loopbackStopped;
        lock (_gate)
        {
            microphone = _microphone;
            loopback = _loopback;
            microphoneStopped = _microphoneStopped?.Task;
            loopbackStopped = _loopbackStopped?.Task;
            _stopRequested = true;
            if (!_microphoneStarted) _microphoneStopped?.TrySetResult(null);
            if (!_loopbackStarted) _loopbackStopped?.TrySetResult(null);
        }

        RequestStop(microphone, _microphoneStopped);
        RequestStop(loopback, _loopbackStopped);

        var waits = new[] { microphoneStopped, loopbackStopped }.Where(task => task is not null).Cast<Task>().ToArray();
        if (waits.Length > 0)
        {
            try
            {
                await Task.WhenAll(waits).ConfigureAwait(false);
            }
            catch
            {
                // Start already failed. Continue cleanup even if native stop
                // also reports an error.
            }
        }

        _clock?.Stop();
        DisposeCaptureObjects();
        ResetSessionState();
    }

    private static void RequestStop(IWaveIn? capture, TaskCompletionSource<object?>? stopped)
    {
        if (capture is null || stopped is null || stopped.Task.IsCompleted)
        {
            return;
        }

        try
        {
            capture.StopRecording();
        }
        catch (Exception exception)
        {
            stopped.TrySetException(exception);
        }
    }

    private void DisposeCaptureObjects()
    {
        var microphone = _microphone;
        var loopback = _loopback;
        var microphoneSink = _microphoneSink;
        var loopbackSink = _loopbackSink;

        if (microphone is not null)
        {
            microphone.DataAvailable -= OnMicrophoneData;
            microphone.RecordingStopped -= OnMicrophoneStopped;
        }
        if (loopback is not null)
        {
            loopback.DataAvailable -= OnLoopbackData;
            loopback.RecordingStopped -= OnLoopbackStopped;
        }

        microphone?.Dispose();
        loopback?.Dispose();
        microphoneSink?.Dispose();
        loopbackSink?.Dispose();

        lock (_gate)
        {
            _microphone = null;
            _loopback = null;
            _microphoneSink = null;
            _loopbackSink = null;
        }
    }

    private void ResetSessionState()
    {
        lock (_gate)
        {
            _sessionActive = false;
            _stopRequested = false;
            _microphoneStopped = null;
            _loopbackStopped = null;
            _clock = null;
            _manifest = null;
            _manifestPath = null;
            _captureWarning = null;
            _microphoneStarted = false;
            _loopbackStarted = false;
        }
    }

    private static int ResolveMicrophoneIndex(string? microphoneId)
    {
        if (WaveIn.DeviceCount <= 0)
        {
            throw new InvalidOperationException("Windows reports no available microphone input devices.");
        }

        if (string.IsNullOrWhiteSpace(microphoneId))
        {
            return 0;
        }

        const string prefix = "wavein:";
        if (!microphoneId.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            || !int.TryParse(microphoneId[prefix.Length..], out var index)
            || index < 0
            || index >= WaveIn.DeviceCount)
        {
            throw new InvalidOperationException("The selected microphone is no longer available. Choose a microphone again.");
        }

        return index;
    }

    private static float CalculateLevel(byte[] buffer, int count)
    {
        if (count < 2)
        {
            return 0;
        }

        double sumSquares = 0;
        var samples = count / 2;
        for (var offset = 0; offset + 1 < count; offset += 2)
        {
            var sample = (short)(buffer[offset] | (buffer[offset + 1] << 8));
            var normalized = sample / 32768.0;
            sumSquares += normalized * normalized;
        }

        return (float)Math.Clamp(Math.Sqrt(sumSquares / Math.Max(1, samples)), 0, 1);
    }

    private static void FinalizeTracks(string targetPath, string? microphonePath, string? systemPath)
    {
        var tracks = new List<AudioFileReader>();
        var providers = new List<ISampleProvider>();
        var temporaryOutput = targetPath + ".halle-finalizing.wav";
        try
        {
            foreach (var path in new[] { microphonePath, systemPath })
            {
                if (path is null || !File.Exists(path) || new FileInfo(path).Length <= 44)
                {
                    continue;
                }

                var reader = new AudioFileReader(path);
                tracks.Add(reader);
                providers.Add(NormalizeForMix(reader));
            }

            if (providers.Count == 0)
            {
                throw new InvalidDataException("No recoverable audio samples were recorded.");
            }

            ISampleProvider output = providers.Count == 1
                ? providers[0]
                : new MixingSampleProvider(providers) { ReadFully = false };

            TryDelete(temporaryOutput);
            WaveFileWriter.CreateWaveFile16(temporaryOutput, output);
            File.Move(temporaryOutput, targetPath, true);
        }
        finally
        {
            foreach (var track in tracks)
            {
                track.Dispose();
            }

            if (File.Exists(temporaryOutput))
            {
                TryDelete(temporaryOutput);
            }
        }
    }

    private static ISampleProvider NormalizeForMix(ISampleProvider source)
    {
        ISampleProvider provider = source.WaveFormat.Channels switch
        {
            1 => new MonoToStereoSampleProvider(source),
            2 => source,
            _ => new DownmixToStereoSampleProvider(source),
        };

        if (provider.WaveFormat.SampleRate != OutputSampleRate)
        {
            provider = new WdlResamplingSampleProvider(provider, OutputSampleRate);
        }

        return provider;
    }

    private static bool RepairWaveHeader(string path)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        if (stream.Length < 44)
        {
            return false;
        }

        using var reader = new BinaryReader(stream, System.Text.Encoding.ASCII, leaveOpen: true);
        using var writer = new BinaryWriter(stream, System.Text.Encoding.ASCII, leaveOpen: true);
        if (new string(reader.ReadChars(4)) != "RIFF")
        {
            return false;
        }

        stream.Position = 8;
        if (new string(reader.ReadChars(4)) != "WAVE")
        {
            return false;
        }

        long dataSizeOffset = -1;
        long dataStart = -1;
        var blockAlign = 1;
        stream.Position = 12;
        while (stream.Position + 8 <= stream.Length)
        {
            var chunkId = new string(reader.ReadChars(4));
            var chunkSize = reader.ReadUInt32();
            var chunkData = stream.Position;

            if (chunkId == "fmt " && chunkSize >= 16 && chunkData + 16 <= stream.Length)
            {
                stream.Position = chunkData + 12;
                blockAlign = Math.Max(1, (int)reader.ReadUInt16());
            }
            else if (chunkId == "data")
            {
                dataSizeOffset = chunkData - 4;
                dataStart = chunkData;
                break;
            }

            var next = chunkData + chunkSize + (chunkSize & 1);
            if (next <= chunkData || next > stream.Length)
            {
                break;
            }
            stream.Position = next;
        }

        if (dataSizeOffset < 0 || dataStart < 0 || dataStart > stream.Length)
        {
            return false;
        }

        var available = stream.Length - dataStart;
        var aligned = available - (available % blockAlign);
        if (aligned <= 0 || aligned > uint.MaxValue)
        {
            return false;
        }

        var effectiveLength = dataStart + aligned;
        stream.Position = dataSizeOffset;
        writer.Write((uint)aligned);
        stream.Position = 4;
        writer.Write((uint)Math.Min(uint.MaxValue, effectiveLength - 8));
        writer.Flush();
        stream.Flush(true);
        return true;
    }

    private static void WriteManifest(string path, RecordingManifest manifest)
    {
        var temporaryPath = path + ".tmp";
        var json = JsonSerializer.Serialize(manifest);
        File.WriteAllText(temporaryPath, json);
        File.Move(temporaryPath, path, true);
    }

    private static string PartialPath(string targetPath, string source)
        => Path.Combine(Path.GetDirectoryName(targetPath)!, $".{Path.GetFileName(targetPath)}.halle-{source}.partial.wav");

    private static string ManifestPath(string targetPath)
        => Path.Combine(Path.GetDirectoryName(targetPath)!, $".{Path.GetFileName(targetPath)}.halle-recording.json");

    private static string SafeCombine(string directory, string fileName)
    {
        if (!string.Equals(Path.GetFileName(fileName), fileName, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Interrupted recording metadata contains an invalid file name.");
        }

        return Path.Combine(directory, fileName);
    }

    private static TaskCompletionSource<object?> NewStoppedSource()
        => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch
        {
            // Cleanup after a successful finalization is best-effort.
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private sealed record RecordingManifest(
        string TargetFileName,
        string MicrophoneFileName,
        string? SystemFileName,
        CaptureMode Mode,
        DateTimeOffset StartedUtc);

    private sealed class TimedWaveSink : IDisposable
    {
        private readonly object _gate = new();
        private readonly WaveFileWriter _writer;
        private readonly WaveFormat _format;
        private readonly Stopwatch _clock;
        private readonly byte[] _zeroBuffer = new byte[64 * 1024];
        private long _dataBytes;
        private bool _disposed;

        public TimedWaveSink(string path, WaveFormat format, Stopwatch clock)
        {
            _format = format;
            _clock = clock;
            _writer = new WaveFileWriter(path, format);
        }

        public void Write(byte[] buffer, int count)
        {
            if (count <= 0)
            {
                return;
            }

            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);

                var callbackEndSeconds = _clock.Elapsed.TotalSeconds;
                var bufferSeconds = count / (double)_format.AverageBytesPerSecond;
                var callbackStartSeconds = Math.Max(0, callbackEndSeconds - bufferSeconds);
                var desiredStartBytes = AlignToBlock((long)(callbackStartSeconds * _format.AverageBytesPerSecond));
                var gapBytes = desiredStartBytes - _dataBytes;
                var toleranceBytes = AlignToBlock((long)(_format.AverageBytesPerSecond * GapToleranceMilliseconds / 1000.0));
                if (gapBytes > toleranceBytes)
                {
                    WriteSilence(gapBytes);
                }

                _writer.Write(buffer, 0, count);
                _writer.Flush();
                _dataBytes += count;
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;
                _writer.Dispose();
            }
        }

        private void WriteSilence(long bytes)
        {
            var remaining = AlignToBlock(bytes);
            while (remaining > 0)
            {
                var count = (int)Math.Min(remaining, _zeroBuffer.Length);
                count -= count % _format.BlockAlign;
                if (count <= 0)
                {
                    break;
                }

                _writer.Write(_zeroBuffer, 0, count);
                _dataBytes += count;
                remaining -= count;
            }
        }

        private long AlignToBlock(long bytes) => bytes - (bytes % _format.BlockAlign);
    }

    private sealed class DownmixToStereoSampleProvider : ISampleProvider
    {
        private readonly ISampleProvider _source;
        private float[] _sourceBuffer = Array.Empty<float>();

        public DownmixToStereoSampleProvider(ISampleProvider source)
        {
            _source = source;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 2);
        }

        public WaveFormat WaveFormat { get; }

        public int Read(float[] buffer, int offset, int count)
        {
            var requestedFrames = count / 2;
            var sourceSamplesNeeded = requestedFrames * _source.WaveFormat.Channels;
            if (_sourceBuffer.Length < sourceSamplesNeeded)
            {
                _sourceBuffer = new float[sourceSamplesNeeded];
            }

            var sourceRead = _source.Read(_sourceBuffer, 0, sourceSamplesNeeded);
            var sourceFrames = sourceRead / _source.WaveFormat.Channels;
            for (var frame = 0; frame < sourceFrames; frame++)
            {
                double sum = 0;
                var sourceOffset = frame * _source.WaveFormat.Channels;
                for (var channel = 0; channel < _source.WaveFormat.Channels; channel++)
                {
                    sum += _sourceBuffer[sourceOffset + channel];
                }

                var mono = (float)(sum / _source.WaveFormat.Channels);
                buffer[offset + frame * 2] = mono;
                buffer[offset + frame * 2 + 1] = mono;
            }

            return sourceFrames * 2;
        }
    }
}
