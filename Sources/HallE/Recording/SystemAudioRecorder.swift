import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Captures ONE app's output audio (e.g. WhatsApp, the remote call party) via a
/// Core Audio process tap → private aggregate device → IOProc → file. macOS 14.2+.
/// Best-effort: callers treat a throw as "mic-only" and keep the note usable.
///
/// NOTE: needs a live-call runtime validation (and the "System Audio Recording"
/// permission). If the per-process tap under-captures on a given WhatsApp build,
/// the global-exclude-self fallback is used.
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

    /// Start capturing `targetBundleID`'s output to `url`. Falls back to a global
    /// tap (excluding our own process) if the target process can't be resolved.
    func start(targetBundleID: String, to url: URL) throws {
        let desc: CATapDescription
        if let proc = Self.processObject(forBundleID: targetBundleID) {
            desc = CATapDescription(stereoMixdownOfProcesses: [proc])
        } else {
            // Fallback: capture everything except ourselves.
            let selfProc = Self.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: selfProc.map { [$0] } ?? [])
        }
        desc.uuid = UUID()
        desc.name = "Hall-e capture"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

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
            try? file.write(from: buffer)
        }
        try check("AudioDeviceCreateIOProcIDWithBlock", st)
        ioProcID = newProcID
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, newProcID))
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
        file = nil
    }

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
