import Foundation

struct RecordingLifecyclePolicy: Equatable {
    var silenceThresholdDB: Float = -45
    var silenceDuration: TimeInterval = 20
    var initialGrace: TimeInterval = 0
    var endPromptTimeout: TimeInterval = 60
    var sourceEndConfirmation: TimeInterval = 6
    var silenceEnabled = true
    var silenceAutoStop = true
    var silencePromptTimeout: TimeInterval = 20
}

enum RecordingLifecycleAction: Equatable {
    case promptForSilence
    case cancelSilencePrompt
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
    var silencePromptedAt: Date?
    var lastObservedAt: Date?

    mutating func observe(now: Date, audioPowerDB: Float, sourceActive: Bool?,
                          policy: RecordingLifecyclePolicy = .init()) -> [RecordingLifecycleAction] {
        var actions: [RecordingLifecycleAction] = []
        if let previous = lastObservedAt, now.timeIntervalSince(previous) > 3 || now < previous {
            if silencePromptedAt != nil { actions.append(.cancelSilencePrompt) }
            silenceBeganAt = nil
            silencePromptedAt = nil
            silenceSuppressedUntilVoice = false
        }
        lastObservedAt = now

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

        guard policy.silenceEnabled, audioPowerDB.isFinite else {
            if silencePromptedAt != nil { actions.append(.cancelSilencePrompt) }
            silenceBeganAt = nil
            silencePromptedAt = nil
            return actions
        }
        guard now.timeIntervalSince(startedAt) >= policy.initialGrace else { return actions }
        if audioPowerDB > policy.silenceThresholdDB {
            if silencePromptedAt != nil { actions.append(.cancelSilencePrompt) }
            silenceBeganAt = nil
            silencePromptedAt = nil
            silenceSuppressedUntilVoice = false
        } else if let promptedAt = silencePromptedAt {
            if policy.silenceAutoStop && now.timeIntervalSince(promptedAt) >= policy.silencePromptTimeout {
                return [.stop(.silencePrompt)]
            }
        } else if !silenceSuppressedUntilVoice {
            if let silenceBeganAt {
                if now.timeIntervalSince(silenceBeganAt) >= policy.silenceDuration {
                    silencePromptedAt = now
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
        silencePromptedAt = nil
        silenceBeganAt = nil
        silenceSuppressedUntilVoice = true
    }

    mutating func resetSilenceObservation() {
        silenceBeganAt = nil
        silencePromptedAt = nil
        silenceSuppressedUntilVoice = false
        lastObservedAt = nil
    }
}
