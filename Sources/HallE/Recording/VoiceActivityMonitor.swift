import AVFoundation
import SoundAnalysis

/// Local-only classification. Unknown/stale analysis disables automatic stopping
/// rather than treating missing audio as silence. No transcript or network call.
final class VoiceActivityMonitor: NSObject, SNResultsObserving {
    private let queue = DispatchQueue(label: "cl.gabriel.hall-e.voice-activity", qos: .utility)
    private let lock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var position: AVAudioFramePosition = 0
    private var pendingCount = 0
    private let sampleRate: Double
    private var captureOrigin: TimeInterval?
    private var uncertainUntil: TimeInterval = -.infinity
    private var settlingDuration: TimeInterval = 3
    private var lastResultAt: TimeInterval = -.infinity
    private var lastVoiceAt: TimeInterval = -.infinity
    private var voice = false

    init(format: AVAudioFormat) throws {
        sampleRate = format.sampleRate
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.overlapFactor = 0.5
        let window = request.windowDuration.seconds
        settlingDuration = window.isFinite && window > 0 ? max(3, window * 2) : 6
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: self)
        self.analyzer = analyzer
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let capturePosition = position
        if captureOrigin == nil { captureOrigin = ProcessInfo.processInfo.systemUptime }
        position += AVAudioFramePosition(buffer.frameLength)
        // Bound memory while allowing the classifier's initial model load.
        // Results are dated by captured frames, so queued analysis cannot make
        // old silence appear fresh.
        guard pendingCount < 64 else {
            uncertainUntil = ProcessInfo.processInfo.systemUptime + settlingDuration
            lastResultAt = -.infinity
            lock.unlock(); return
        }
        pendingCount += 1
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.lock(); pendingCount -= 1; uncertainUntil = ProcessInfo.processInfo.systemUptime + settlingDuration; lock.unlock(); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(source, destination) {
            if let s = src.mData, let d = dst.mData { memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize))) }
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.analyzer?.analyze(copy, atAudioFramePosition: capturePosition)
            self.lock.lock(); self.pendingCount -= 1; self.lock.unlock()
        }
    }

    var hasVoice: Bool? {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= uncertainUntil, now - lastResultAt < 3 else { return nil }
        return voice || now - lastVoiceAt < 1.5
    }

    func invalidate() {
        lock.lock()
        uncertainUntil = ProcessInfo.processInfo.systemUptime + settlingDuration
        lastResultAt = -.infinity
        lock.unlock()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let detected = result.classifications.contains {
            ($0.identifier == "speech" || $0.identifier.contains("speaking") || $0.identifier == "conversation") && $0.confidence >= 0.25
        }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let end = result.timeRange.start.seconds + result.timeRange.duration.seconds
        lastResultAt = end.isFinite ? min(now, (captureOrigin ?? now) + end) : -.infinity
        voice = detected
        if detected { lastVoiceAt = lastResultAt }
        lock.unlock()
    }
    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); lastResultAt = -.infinity; lock.unlock()
    }
    func requestDidComplete(_ request: SNRequest) {}
}

final class MicrophoneVoiceMonitor {
    private let engine = AVAudioEngine()
    private var monitor: VoiceActivityMonitor?
    private var installedTap = false

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "HallE.VoiceActivity", code: 1)
        }
        let monitor = try VoiceActivityMonitor(format: format)
        self.monitor = monitor
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in monitor.consume(buffer) }
        installedTap = true
        try engine.start()
    }
    var hasVoice: Bool? { monitor?.hasVoice }
    func invalidate() { monitor?.invalidate() }
    func stop() {
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        monitor = nil
    }
    deinit { stop() }
}
