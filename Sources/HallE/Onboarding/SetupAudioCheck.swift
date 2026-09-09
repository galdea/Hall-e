import Foundation
import AVFoundation
import Observation

/// An explicitly started disposable check. Never uploads audio or enters the library.
@MainActor @Observable
final class SetupAudioCheck {
    enum Phase { case idle, recording, transcribing, completed, failed }
    private(set) var phase: Phase = .idle
    private(set) var secondsRemaining = 8
    private(set) var level: Double = 0
    private(set) var heardAudio = false
    private(set) var text = ""
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var temporaryFolder: URL?
    private var generation = UUID()
    var isRunning: Bool { phase == .recording || phase == .transcribing }

    func start(language: String, transcribe: Bool) {
        cancel()
        let run = UUID()
        generation = run
        phase = .recording
        secondsRemaining = 8
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw CheckError.microphoneDenied }
                try Task.checkCancellation()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Hall-e-audio-check-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                self.temporaryFolder = folder
                let audio = folder.appendingPathComponent("sample.m4a")
                let recorder = try AVAudioRecorder(url: audio, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                    AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ])
                recorder.isMeteringEnabled = true
                self.recorder = recorder
                guard recorder.record() else { throw CheckError.cannotRecord }
                self.meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == run, let recorder = self.recorder else { return }
                        recorder.updateMeters()
                        let power = recorder.averagePower(forChannel: 0)
                        self.level = min(1, max(0, Double(power + 60) / 60))
                        if power > -45 { self.heardAudio = true }
                    }
                }
                for second in (0..<8).reversed() {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    self.secondsRemaining = second
                }
                self.stopCapture()
                guard self.heardAudio else { throw CheckError.noAudio }
                if transcribe {
                    self.phase = .transcribing
                    let transcript = try await LocalTranscriptionProvider().transcribe(
                        fileURL: audio, sessionID: run, track: "mic", language: language)
                    try Task.checkCancellation()
                    guard !transcript.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckError.noWords }
                    self.text = transcript.plainText
                }
                self.phase = .completed
            } catch is CancellationError {
                // cancel() already reset the UI.
            } catch {
                guard self.generation == run else { return }
                self.error = error.localizedDescription
                self.phase = .failed
            }
            guard self.generation == run else { return }
            self.stopCapture()
            self.removeSample()
            self.task = nil
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        stopCapture(); removeSample()
        phase = .idle; level = 0; heardAudio = false; text = ""; error = nil
    }

    private func stopCapture() {
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil; level = 0
    }
    private func removeSample() {
        if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
        temporaryFolder = nil
    }
    private enum CheckError: LocalizedError {
        case microphoneDenied, cannotRecord, noAudio, noWords
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return PublicUICopy.text("Allow Hall-e in System Settings → Privacy & Security → Microphone, then try again.", "Autoriza Hall-e en Ajustes del Sistema → Privacidad y seguridad → Micrófono y vuelve a intentar.")
            case .cannotRecord: return PublicUICopy.text("The microphone could not start. Check your input device in Sound settings.", "No se pudo iniciar el micrófono. Revisa el dispositivo de entrada en los ajustes de Sonido.")
            case .noAudio: return PublicUICopy.text("No clear audio was detected. Check that your microphone is not muted and try speaking closer to it.", "No se detectó audio claro. Revisa que el micrófono no esté silenciado e intenta hablar más cerca.")
            case .noWords: return PublicUICopy.text("Audio was detected, but no words were recognized. Check the meeting language and try again.", "Se detectó audio, pero no palabras. Revisa el idioma de la reunión y vuelve a intentar.")
            }
        }
    }
}
