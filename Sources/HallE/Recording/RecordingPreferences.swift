import Foundation

extension AppPreferences {
    static var silenceDetectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "silenceDetectionEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "silenceDetectionEnabled") }
    }
    static var silenceAutoStopEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "silenceAutoStopEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "silenceAutoStopEnabled") }
    }
    static var recordingSilenceSeconds: Double {
        get { boundedRecordingInterval("recordingSilenceSeconds", range: 5...300) }
        set { UserDefaults.standard.set(newValue.isFinite ? min(300, max(5, newValue)) : 20, forKey: "recordingSilenceSeconds") }
    }
    static var recordingConfirmationSeconds: Double {
        get { boundedRecordingInterval("recordingConfirmationSeconds", range: 5...120) }
        set { UserDefaults.standard.set(newValue.isFinite ? min(120, max(5, newValue)) : 20, forKey: "recordingConfirmationSeconds") }
    }
    private static func boundedRecordingInterval(_ key: String, range: ClosedRange<Double>) -> Double {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double, value.isFinite else { return 20 }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
