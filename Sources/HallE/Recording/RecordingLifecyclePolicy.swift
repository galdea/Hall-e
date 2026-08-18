import Foundation

struct RecordingLifecyclePolicy: Equatable {
    var silenceThresholdDB: Float = -45
    var silenceDuration: TimeInterval = 20
    var initialGrace: TimeInterval = 5
    var endPromptTimeout: TimeInterval = 60
    var sourceEndConfirmation: TimeInterval = 6
}

enum RecordingLifecycleAction: Equatable {
    case promptForSilence
    case promptForScheduledEnd
    case stop(RecordingStopReason)
}

struct RecordingLifecycleState: Equatable {
    var startedAt: Date
    var scheduledEndAt: Date?
    var silenceBeganAt: Date?
    var silenceSuppressedUntilVoice = false
    var scheduledEndPromptedAt: Date?
    var sourceEndedAt: Date?

    mutating func observe(now: Date, audioPowerDB: Float, sourceActive: Bool?,
                          policy: RecordingLifecyclePolicy = .init()) -> [RecordingLifecycleAction] {
        var actions: [RecordingLifecycleAction] = []

        if let sourceActive {
            if sourceActive {
                sourceEndedAt = nil
            } else if let sourceEndedAt {
                if now.timeIntervalSince(sourceEndedAt) >= policy.sourceEndConfirmation {
                    return [.stop(.sourceEnded)]
                }
            } else {
                sourceEndedAt = now
            }
        }

        if let scheduledEndAt, now >= scheduledEndAt {
            if policy.endPromptTimeout <= 0 { return [.stop(.scheduledEnd)] }
            if let promptedAt = scheduledEndPromptedAt {
                if now.timeIntervalSince(promptedAt) >= policy.endPromptTimeout {
                    return [.stop(.scheduledEnd)]
                }
            } else {
                scheduledEndPromptedAt = now
                actions.append(.promptForScheduledEnd)
            }
        }

        guard now.timeIntervalSince(startedAt) >= policy.initialGrace else { return actions }
        if audioPowerDB > policy.silenceThresholdDB {
            silenceBeganAt = nil
            silenceSuppressedUntilVoice = false
        } else if !silenceSuppressedUntilVoice {
            if let silenceBeganAt {
                if now.timeIntervalSince(silenceBeganAt) >= policy.silenceDuration {
                    silenceSuppressedUntilVoice = true
                    actions.append(.promptForSilence)
                }
            } else {
                silenceBeganAt = now
            }
        }
        return actions
    }

    mutating func extend(by interval: TimeInterval, now: Date = Date()) {
        scheduledEndAt = now.addingTimeInterval(interval)
        scheduledEndPromptedAt = nil
    }

    mutating func keepAfterSilence() {
        silenceSuppressedUntilVoice = true
    }
}
