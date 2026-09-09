import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Captures ONE app's output audio (e.g. WhatsApp, the remote call party) via a
/// Core Audio process tap → private aggregate device → IOProc → file. macOS 14.2+.
/// Best-effort: callers treat a throw as "mic-only" and keep the note usable.
///
/// Requires the macOS audio recording permission. A missing target fails
/// explicitly; it must never expand a per-app choice to all system audio.
@available(macOS 14.2, *)
final class SystemAudioRecorder {
    enum CaptureError: Error, LocalizedError {
        case processNotFound
        case osStatus(String, OSStatus)
        case badFormat
        var errorDescription: String? {
            switch self {
            case .processNotFound: "Target app has no capturable audio process."
            case .osStatus(let op, let s): "\(op) failed (OSStatus \(s))."
            case .badFormat: "Could not read the tap's audio format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let ioQueue = DispatchQueue(label: "cl.gabriel.hall-e.systemaudio")
    private let powerLock = NSLock()
    private var latestPowerDB: Float = -160
    private var latestPowerAt = Date.distantPast
    private var voiceMonitor: VoiceActivityMonitor?

    /// Start capturing only `targetBundleID`'s output to `url`.
    func start(targetBundleID: String, to url: URL) throws {
        // Mix down EVERY process object in the app's bundle family (main app +
        // any helper/renderer), not just the first match — an outgoing or video
        // call can route its audio through a different process than a voice call.
        let procs = Self.processObjects(forBundleID: targetBundleID)
        let desc: CATapDescription
        guard !procs.isEmpty else { throw CaptureError.processNotFound }
        desc = CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID()
        desc.name = "Hall-e capture"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        do {
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(desc, &tap))
        guard tap != kAudioObjectUnknown else { throw CaptureError.processNotFound }
        tapID = tap

        // Tap output format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check("get tap format", AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd))
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.badFormat }
        voiceMonitor = try? VoiceActivityMonitor(format: format)

        // Private aggregate device: real default output as the main sub-device
        // (a tap-only aggregate silently yields zero samples) + our tap.
        var settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hall-e Capture",
            kAudioAggregateDeviceUIDKey: "cl.gabriel.hall-e.agg.\(desc.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outUID = Self.defaultOutputDeviceUID() {
            settings[kAudioAggregateDeviceMainSubDeviceKey] = outUID
            settings[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(settings as CFDictionary, &agg))
        aggregateID = agg

        file = try AVAudioFile(forWriting: url, settings: format.settings)
        let fmt = format
        var newProcID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            self.updatePower(from: buffer)
            self.voiceMonitor?.consume(buffer)
            try? file.write(from: buffer)
        }
        try check("AudioDeviceCreateIOProcIDWithBlock", st)
        ioProcID = newProcID
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, newProcID))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // The IOProc block reads `file` on `ioQueue`; clear it there so any
        // in-flight callback finishes its write before the file closes.
        ioQueue.sync { file = nil; voiceMonitor = nil }
        powerLock.lock(); latestPowerDB = -160; powerLock.unlock()
    }

    func currentPowerDB() -> Float {
        powerLock.lock(); defer { powerLock.unlock() }
        return Date().timeIntervalSince(latestPowerAt) > 1.5 ? -160 : latestPowerDB
    }

    func currentVoiceActivity() -> Bool? { voiceMonitor?.hasVoice }
    func invalidateVoiceActivity() { voiceMonitor?.invalidate() }

    private func updatePower(from buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        var sum: Float = 0
        if buffer.format.isInterleaved {
            let samples = channels[0]
            for index in 0..<(frames * channelCount) { sum += samples[index] * samples[index] }
        } else {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for index in 0..<frames { sum += samples[index] * samples[index] }
            }
        }
        let rms = sqrt(sum / Float(frames * channelCount))
        let db = rms > 0 ? 20 * log10(rms) : -160
        powerLock.lock(); latestPowerDB = db; latestPowerAt = Date(); powerLock.unlock()
    }

    deinit { stop() }

    // MARK: - Lookups

    private func check(_ op: String, _ status: OSStatus) throws {
        if status != noErr { throw CaptureError.osStatus(op, status) }
    }

    static func processObject(forBundleID bundleID: String) -> AudioObjectID? {
        for proc in allProcessObjects() {
            if stringProperty(proc, kAudioProcessPropertyBundleID) == bundleID { return proc }
        }
        return nil
    }

    /// Every audio process object in an app's bundle family: the exact bundle id
    /// plus any sub-bundle (e.g. `net.whatsapp.WhatsApp.*` helpers/extensions).
    /// Used for both the tap and mic-in-use detection so we don't miss the one
    /// process that happens to carry the call audio on a given build.
    static func processObjects(forBundleID bundleID: String) -> [AudioObjectID] {
        allProcessObjects().filter { proc in
            guard let bid = stringProperty(proc, kAudioProcessPropertyBundleID) else { return false }
            return bid == bundleID || bid.hasPrefix(bundleID + ".")
        }
    }

    /// Human-readable dump of active-audio / WhatsApp process objects. Reads only
    /// public properties (no capture) so it needs NO permission. Used by the
    /// `HALLE_DEBUG_AUDIO_PROCESSES=1` diagnostic to confirm, during a live call,
    /// which WhatsApp process is producing input/output.
    static func diagnostics() -> String {
        var lines: [String] = []
        for proc in allProcessObjects() {
            let bid = stringProperty(proc, kAudioProcessPropertyBundleID) ?? "(no bundle id)"
            let inp = isRunningInput(proc), out = isRunningOutput(proc)
            if inp || out || bid.lowercased().contains("whatsapp") {
                lines.append("obj \(proc)  in:\(inp ? "YES" : "no")  out:\(out ? "YES" : "no")  \(bid)")
            }
        }
        if lines.isEmpty { lines.append("(no active-audio or WhatsApp process objects found)") }
        return lines.joined(separator: "\n")
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var inPID = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &inPID) { p -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), p, &size, &obj)
        }
        return st == noErr ? obj : nil
    }

    static func allProcessObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var procs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procs) == noErr else { return [] }
        return procs
    }

    /// Is this process object currently rendering output (used by the detector)?
    static func isRunningOutput(_ proc: AudioObjectID) -> Bool {
        runningFlag(proc, kAudioProcessPropertyIsRunningOutput)
    }

    /// Is this process currently using the mic (used by the call auto-prompt)?
    static func isRunningInput(_ proc: AudioObjectID) -> Bool {
        runningFlag(proc, kAudioProcessPropertyIsRunningInput)
    }

    private static func runningFlag(_ proc: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf)
        guard st == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr else { return nil }
        return stringProperty(devID, kAudioDevicePropertyDeviceUID)
    }
}
