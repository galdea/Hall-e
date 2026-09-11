import Foundation
import AppKit
import AVFoundation

/// End-to-end local recording pipeline. A completed audio file is never treated
/// as disposable merely because Speech, a vault, or one of two audio tracks
/// fails: the durable job can always be retried from its own folder.
@MainActor
enum RecordingCoordinator {
    private static var recovering = false
    private static var scheduledCloudRetries: [UUID: Task<Void, Never>] = [:]
    private static var activeSessions = Set<UUID>()

    static func isProcessing(sessionID: UUID) -> Bool {
        activeSessions.contains(sessionID)
    }

    static func cancelScheduledRetry(sessionID: UUID) {
        scheduledCloudRetries.removeValue(forKey: sessionID)?.cancel()
    }

    static func startRecording(for event: UnifiedEvent) {
        guard RecordingService.shared.isRecording == false else { return }
        let consent = NSAlert()
        consent.messageText = "Record this meeting?"
        consent.informativeText = "Hall-e records locally. Tell every participant before recording."
        consent.addButton(withTitle: "Start Recording")
        consent.addButton(withTitle: "Cancel")
        guard consent.runModal() == .alertFirstButtonReturn else { return }
        startMeetingRecording(event, sourceKind: .calendarMeeting)
    }

    static func startAutomaticRecording(for event: UnifiedEvent) {
        guard AppPreferences.autoRecordCalendarMeetings,
              event.meetingURL != nil,
              RecordingService.shared.isRecording == false else { return }
        startMeetingRecording(event, sourceKind: .calendarMeeting)
    }

    /// Called after the explicit browser/call prompt. The prompt itself is the
    /// consent action, so do not show a second competing dialog here.
    static func startDetectedCall(for event: UnifiedEvent, identity: CallIdentity,
                                  localEvent: LocalCaptureEvent? = nil) {
        guard RecordingService.shared.isRecording == false else { return }
        let notePath = ensureNote(for: event, kind: localEvent == nil ? .meeting : .call)
        let source = identity.provider.recordingSource
        Task {
            let sessionID = await RecordingService.shared.startCall(for: event, notePath: notePath, sourceKind: source) { session in
                Task {
                    if let localID = session.localCaptureEventID {
                        await LocalCaptureEventStore.shared.finish(id: localID)
                    }
                    if localEvent == nil {
                        await transcribeAndMerge(session: session, event: event)
                    } else {
                        await finishCall(session: session, event: event)
                    }
                }
            }
            if let sessionID { RecordingService.shared.attachCall(sessionID: sessionID, identityKey: identity.key, localCaptureEventID: localEvent?.id) }
        }
    }

    private static func startMeetingRecording(_ event: UnifiedEvent, sourceKind: RecordingSourceKind) {
        let notePath = ensureNote(for: event, kind: .meeting)
        Task {
            await RecordingService.shared.start(for: event, notePath: notePath, sourceKind: sourceKind) { session in
                Task { await transcribeAndMerge(session: session, event: event) }
            }
        }
    }

    private static func ensureNote(for event: UnifiedEvent, kind: NoteKind) -> String? {
        guard let service = MeetingNoteService.make() else { return nil }
        do {
            return try service.createOrFindMeetingNote(for: event, projectName: event.projectId, kind: kind).vaultRelativePath
        } catch {
            Log.rec.error("note ensure failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Durable transcription

    /// Runs after a meeting recording stops, and also for a retry after relaunch.
    static func transcribeAndMerge(session incoming: RecordingSession, event: UnifiedEvent) async {
        // A deferred callback may arrive after explicit deletion. Never revive
        // it from an in-memory snapshot: checkpoint saves create directories.
        guard var session = RecordingStore.allSessions().first(where: { $0.id == incoming.id }) else { return }
        guard activeSessions.insert(incoming.id).inserted else { return }
        defer { activeSessions.remove(incoming.id) }
        if let playback = await RecordingMixdownService.makePlaybackMix(for: session) {
            session.playbackFileName = playback
            session.save(); notifyRecordingChanged()
        }
        guard let result = await transcribeTracks(session: session) else {
            let latest = RecordingStore.allSessions().first(where: { $0.id == session.id })
            updateVaultTranscriptStatus(session: latest ?? session,
                                        value: latest?.transcriptionJob?.status.rawValue ?? "retryable-failed")
            return
        }
        session = result.session
        let transcript = result.transcript

        let service = MeetingNoteService.make()
        var notePath = session.notePath
        if notePath == nil, let available = service {
            do {
                let descriptor = try available.createOrFindMeetingNote(for: event, projectName: event.projectId)
                notePath = descriptor.vaultRelativePath
                session.notePath = notePath
                session.save()
            } catch { Log.obsidian.error("late note creation failed: \(error, privacy: .public)") }
        }
        // Name and file the recording before the note is pointed at it: the
        // transcript is already durable on disk, and doing it here means
        // `recording_path` is written once, at the final location.
        session = await RecordingLibrary.fileByContent(session: session, event: event,
                                                       transcript: transcript.plainText)
        notifyRecordingChanged()

        if let service, let notePath {
            let pb = VaultPathBuilder(config: service.config)
            let writer = VaultWriter(vaultURL: service.vaultURL)
            attemptVaultUpdate("recording_path frontmatter") {
                try writer.updateFrontmatter(relativePath: notePath, key: "recording_path",
                                              value: session.folderURL.path, pathBuilder: pb)
            }
            attemptVaultUpdate("transcript merge") {
                try writer.mergeSection(relativePath: notePath, section: "transcript",
                                        newContent: transcriptBody(transcript),
                                        headingAnchor: "Transcript", mode: .replace, pathBuilder: pb)
            }
            attemptVaultUpdate("transcript_status frontmatter") {
                try writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                              value: "completed", pathBuilder: pb)
            }
            let context = MeetingContext(title: event.title, project: event.projectId,
                                         date: HalleDate.day(event.startTs),
                                         attendees: event.attendees.compactMap { $0.email })
            if AppPreferences.allowCloudTranscriptReports {
                session = await MeetingBriefingPipeline.run(session: session, transcript: transcript,
                                                            context: context, service: service, notePath: notePath)
            } else {
                await TranscriptPostProcessor(service: service, notePath: notePath, context: context)
                    .enrich(transcript: transcript.plainText)
            }
        }
        await VaultIndex.shared.reindex()
    }

    /// Manual WhatsApp entry remains available; all provider calls now use the
    /// same persisted multi-track transcriber.
    static func startCallRecording() {
        guard RecordingService.shared.isRecording == false else { return }
        let consent = NSAlert()
        consent.messageText = "Record this WhatsApp call?"
        consent.informativeText = "Hall-e records locally. Tell the other participant before recording."
        consent.addButton(withTitle: "Record")
        consent.addButton(withTitle: "Cancel")
        guard consent.runModal() == .alertFirstButtonReturn else { return }
        let event = CallEvent.makeWhatsAppCall()
        Task {
            await RecordingService.shared.startCall(for: event, notePath: nil, sourceKind: .whatsAppCall) { session in
                Task { await finishCall(session: session, event: event) }
            }
        }
    }

    static func finishCall(session incoming: RecordingSession, event: UnifiedEvent) async {
        guard var session = RecordingStore.allSessions().first(where: { $0.id == incoming.id }) else { return }
        guard activeSessions.insert(incoming.id).inserted else { return }
        defer { activeSessions.remove(incoming.id) }
        if let playback = await RecordingMixdownService.makePlaybackMix(for: session) {
            session.playbackFileName = playback
            session.save(); notifyRecordingChanged()
        }
        guard let result = await transcribeTracks(session: session) else { return }
        session = result.session
        let transcript = result.transcript

        var classified = event
        classified.descriptionText = transcript.plainText
        let classifier = MeetingClassifier()
        var classification = classifier.classifyTranscript(text: transcript.plainText)
        let provider = LLMProviderFactory.make()
        if !(provider is DisabledLLMProvider), !classifier.isConfident(classification),
           let ai = await classifier.aiClassify(classified, provider: provider) {
            classification = ai
        }
        let projectName = classification.requires_user_confirmation ? nil : classification.project
        classified.projectId = projectName
        classified.projectConfidence = classification.confidence

        guard let service = MeetingNoteService.make() else { return }
        do {
            let descriptor = try service.createOrFindMeetingNote(for: classified, projectName: projectName, kind: .call)
            session.notePath = descriptor.vaultRelativePath
            session.save()
            if let localID = session.localCaptureEventID {
                await LocalCaptureEventStore.shared.updateNote(id: localID, notePath: descriptor.vaultRelativePath)
            }
            // File the call now that the transcript has told us which project it
            // belongs to — a call starts out unclassified by definition.
            session = await RecordingLibrary.fileByContent(session: session, event: classified,
                                                           transcript: transcript.plainText)
            notifyRecordingChanged()
            let pb = VaultPathBuilder(config: service.config)
            let writer = VaultWriter(vaultURL: service.vaultURL)
            attemptVaultUpdate("call recording_path frontmatter") {
                try writer.updateFrontmatter(relativePath: descriptor.vaultRelativePath, key: "recording_path",
                                              value: session.folderURL.path, pathBuilder: pb)
            }
            attemptVaultUpdate("call transcript merge") {
                try writer.mergeSection(relativePath: descriptor.vaultRelativePath, section: "transcript",
                                        newContent: transcriptBody(transcript), headingAnchor: "Transcript",
                                        mode: .replace, pathBuilder: pb)
            }
            attemptVaultUpdate("call transcript_status frontmatter") {
                try writer.updateFrontmatter(relativePath: descriptor.vaultRelativePath, key: "transcript_status",
                                              value: "completed", pathBuilder: pb)
            }
            let context = MeetingContext(title: classified.title, project: projectName,
                                         date: HalleDate.day(classified.startTs), attendees: [])
            if AppPreferences.allowCloudTranscriptReports {
                session = await MeetingBriefingPipeline.run(session: session, transcript: transcript,
                                                            context: context, service: service,
                                                            notePath: descriptor.vaultRelativePath)
            } else {
                await TranscriptPostProcessor(service: service, notePath: descriptor.vaultRelativePath, context: context)
                    .enrich(transcript: transcript.plainText)
            }
            await VaultIndex.shared.reindex()
        } catch { Log.rec.error("call note creation failed: \(error, privacy: .public)") }
    }

    static func retry(session: RecordingSession) {
        guard !activeSessions.contains(session.id) else { return }
        guard RecordingStore.queueRetry(slug: session.slug) != nil else { return }
        notifyRecordingChanged()
        Task { await resumeQueuedJobsWhenIdle() }
    }

    static func retryAll() {
        let sessions = RecordingStore.allSessions().filter {
            !activeSessions.contains($0.id)
                && ($0.transcriptionJob ?? .legacy(status: $0.transcriptStatus)).status == .retryableFailed
        }
        for session in sessions { _ = RecordingStore.queueRetry(slug: session.slug) }
        notifyRecordingChanged()
        Task { await resumeQueuedJobsWhenIdle() }
    }

    /// Re-runs a completed session from its original audio. This clears the
    /// completed-job short circuit and transcript file so a new engine/language
    /// cannot accidentally reuse the old result.
    static func retranscribe(session: RecordingSession) {
        guard !activeSessions.contains(session.id) else { return }
        guard RecordingStore.queueRetranscription(slug: session.slug) != nil else { return }
        notifyRecordingChanged()
        Task { await resumeQueuedJobsWhenIdle() }
    }

    static func resumeQueuedJobsWhenIdle() async {
        guard !recovering else {
            Log.rec.info("transcription recovery skipped: another recovery is active")
            return
        }
        guard RecordingService.shared.canProcessQueuedTranscriptions else {
            Log.rec.info("transcription recovery skipped: recorder is active")
            return
        }
        recovering = true
        defer { recovering = false }
        // Avoid a busy loop if metadata cannot be saved. A later persisted
        // attempt may still become due while another recording is processing.
        var attemptedCounts: [UUID: Int] = [:]
        while RecordingService.shared.canProcessQueuedTranscriptions {
            let sessions = RecordingStore.queuedSessions().filter {
                !activeSessions.contains($0.id)
                    && attemptedCounts[$0.id] != ($0.transcriptionJob?.attemptCount ?? 0)
            }
            for session in sessions {
                if let date = session.transcriptionJob?.cloud?.retryAfter, date > Date(),
                   scheduledCloudRetries[session.id] == nil {
                    scheduleCloudRetry(sessionID: session.id, after: date.timeIntervalSinceNow)
                }
            }
            guard let session = sessions.first(where: {
                ($0.transcriptionJob ?? .legacy(status: $0.transcriptStatus)).isDueForAutomaticRetry()
            }) else { return }
            attemptedCounts[session.id] = session.transcriptionJob?.attemptCount ?? 0
            Log.rec.info("transcription recovery starting \(session.slug, privacy: .public)")
            await resume(session)
        }
    }

    private static func resume(_ session: RecordingSession) async {
        guard RecordingService.shared.canProcessQueuedTranscriptions,
              !activeSessions.contains(session.id),
              let session = RecordingStore.allSessions().first(where: { $0.id == session.id }),
              (session.transcriptionJob ?? .legacy(status: session.transcriptStatus)).isDueForAutomaticRetry() else { return }
        let event = session.eventSnapshot ?? recoveryEvent(for: session)
        if session.localCaptureEventID != nil || session.sourceKind == .whatsAppCall || session.eventDedupKey.hasPrefix("whatsapp:") {
            await finishCall(session: session, event: event)
        } else {
            await transcribeAndMerge(session: session, event: event)
        }
    }

    private static func recoveryEvent(for session: RecordingSession) -> UnifiedEvent {
        UnifiedEvent(dedupKey: session.eventDedupKey, title: session.eventTitle,
                     startTs: session.eventStartAt ?? session.startedAt,
                     endTs: session.endedAt ?? session.startedAt, isAllDay: false,
                     status: "confirmed", effectiveResponse: nil, meetingURL: nil, location: nil,
                     descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                     iCalUID: nil, winnerAccountEmail: AppPreferences.primaryAccountEmail ?? "",
                     projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
    }

    private static func transcribeTracks(session initial: RecordingSession) async -> (session: RecordingSession, transcript: Transcript)? {
        var session = initial
        var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
        if job.status == .completed, let transcript = TranscriptStore.load(session) {
            return (session, transcript)
        }
        if CloudFallbackPolicy.requiresReview(job.cloud) {
            job.status = .ambiguousBilling
            job.lastError = "The prior cloud upload has no confirmed outcome. Review it before submitting audio again."
            session.transcriptionJob = job
            session.transcriptStatus = .failed
            session.save(); notifyRecordingChanged()
            return nil
        }
        job.beginAttempt()
        session.transcriptionJob = job
        session.transcriptStatus = .inProgress
        session.save(); notifyRecordingChanged()

        let savedTranscript = TranscriptStore.load(session)
        let prior = savedTranscript ?? Transcript(sessionID: session.id, localeUsed: session.localeUsed ?? "en-US",
                                                                segments: [], status: .pending, source: "sfspeech-on-device")
        let tracks = availableTracks(for: session)
        guard !tracks.isEmpty else {
            return markJobFailed(session: session, message: "No recording audio is available.")
        }

        let languagePreference = AppPreferences.transcriptionLanguage
        let preference = AppPreferences.transcriptionEngine
        let resolved = TranscriptionEngineResolver.resolve(
            preference: preference,
            language: languagePreference,
            availability: cloudAvailability(),
            checkpoint: job.cloud
        )

        // A returned Speechmatics job ID is a durable remote checkpoint. Resume
        // it regardless of a later global engine change; creating a different
        // provider request here could double-charge the same recording.
        if job.cloud?.provider == .speechmatics, job.cloud?.providerJobID != nil {
            return await transcribeSpeechmatics(session: session, prior: prior)
        }

        if case .deepgram = resolved {
            return await transcribeDeepgram(session: session, prior: prior, preference: preference)
        }
        if case .speechmatics = resolved {
            return await transcribeSpeechmatics(session: session, prior: prior)
        }

        let persistence = TranscriptionCheckpointPersistence(session: session, transcript: prior)
        var successfulTrack = false
        var failedTrack = false
        var locale = prior.localeUsed

        for input in tracks {
            let current = await persistence.track(named: input.track)
            if current?.status == .completed, savedTranscript != nil {
                successfulTrack = true
                continue
            }
            await persistence.beginTrack(input.track, fileName: input.url.lastPathComponent)
            let existing = await persistence.segments(for: input.track)
            // If transcript.json was lost, recompute instead of trusting orphaned
            // checkpoint flags. Repeating a chunk is safer than silently omitting it.
            let completed = existing.isEmpty ? [] : (await persistence.completedChunks(for: input.track))
            do {
                let result: Transcript
                switch resolved {
                case .deepgram:
                    // The whole mixed file is uploaded once so speaker labels
                    // remain stable across the meeting. Handled above.
                    throw DeepgramError.invalidResponse("Deepgram track routing error.")
                case .speechmatics:
                    throw SpeechmaticsError.invalidResponse("Speechmatics track routing error.")
                case .sfSpeech(let language):
                    result = try await LocalTranscriptionProvider().transcribe(
                        fileURL: input.url, sessionID: session.id, track: input.track,
                        existingSegments: existing, completedChunkIndexes: completed,
                        language: language, timelineOffset: session.timelineOffset(for: input.track),
                        onPrepared: { chunks in
                            await persistence.configure(track: input.track, chunks: chunks)
                        },
                        onCheckpoint: { checkpoint in
                            await persistence.checkpoint(track: input.track, checkpoint: checkpoint)
                        })
                }
                locale = result.localeUsed
                successfulTrack = true
                await persistence.complete(track: input.track, locale: locale, source: result.source)
            } catch {
                failedTrack = true
                await persistence.fail(track: input.track, message: TranscriptionErrorSanitizer.message(error))
            }
        }

        // The model is deliberately held across mic + system tracks, then
        // released before the next queued recording starts.

        var snapshot = await persistence.snapshot()
        if successfulTrack && !failedTrack {
            snapshot.session.transcriptionJob?.status = .completed
            snapshot.session.transcriptionJob?.completedAt = Date()
            snapshot.session.transcriptionJob?.lastError = nil
            snapshot.session.transcriptStatus = .completed
            snapshot.session.localeUsed = locale
            snapshot.transcript.localeUsed = locale
            snapshot.transcript.status = .completed
            snapshot.transcript.segments.sort { $0.start < $1.start }
            TranscriptStore.save(snapshot.transcript, to: snapshot.session)
            snapshot.session.save(); notifyRecordingChanged()
            return (snapshot.session, snapshot.transcript)
        }
        let message = snapshot.session.transcriptionJob?.tracks.compactMap(\.lastError).first
            ?? "Hall-e could not transcribe the available audio."
        return markJobFailed(session: snapshot.session, message: message)
    }

    private static func cloudAvailability() -> CloudFallbackPolicy.Availability {
        .init(deepgramConfigured: !DeepgramTranscriptionProvider.credentials().isEmpty,
              deepgramConsented: AppPreferences.allowCloudAudioTranscription,
              speechmaticsConfigured: AppPreferences.speechmaticsRegion?.isSupported == true
                  && !(KeychainStore.get(account: KeychainStore.speechmaticsTranscriptionAccount) ?? "").isEmpty,
              speechmaticsConsented: AppPreferences.allowSpeechmaticsAudioTranscription)
    }

    private static func transcribeDeepgram(session initial: RecordingSession,
                                           prior: Transcript,
                                           preference: TranscriptionEnginePreference) async -> (session: RecordingSession, transcript: Transcript)? {
        var session = initial
        let audioURL = session.playbackURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return markJobFailed(session: session, message: "No mixed recording audio is available for Deepgram.")
        }
        let assetDuration = (try? await AVURLAsset(url: audioURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
        let duration = assetDuration.isFinite && assetDuration > 0
            ? assetDuration : max(0, (session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        let estimate = DeepgramConfiguration.estimatedCostUSD(duration: duration)
        var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
        job.cloud = .init(state: AppPreferences.allowCloudAudioTranscription ? .uploading : .consentBlocked,
                          requestFingerprint: "pending-audio-hash", estimatedCostUSD: estimate,
                          requestID: nil, retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil,
                          updatedAt: Date())
        session.transcriptionJob = job
        session.save(); notifyRecordingChanged()

        do {
            let provider = DeepgramTranscriptionProvider(configuration: .init(),
                                                         rawResponseDirectory: session.folderURL,
                                                         duration: duration,
                                                         responseCache: AppPaths.deepgramResponseCacheDir)
            var replacement = try await provider.transcribe(fileURL: audioURL, sessionID: session.id, track: "mixed")
            replacement.status = .completed
            job.status = .completed
            job.completedAt = Date()
            job.lastError = nil
            job.cloud = .init(state: .completed,
                              requestFingerprint: replacement.providerMetadata?.audioSHA256 ?? "unknown",
                              estimatedCostUSD: estimate,
                              requestID: replacement.providerMetadata?.requestID,
                              retryAfter: nil, lastHTTPStatus: 200, lastErrorCode: nil,
                              updatedAt: Date())
            session.transcriptionJob = job
            session.transcriptStatus = .completed
            session.localeUsed = replacement.localeUsed
            TranscriptStore.save(replacement, to: session)
            session.save(); notifyRecordingChanged()
            await DeepgramCreditMonitor.noteCredentialUsed(replacement.providerMetadata?.credential)
            return (session, replacement)
        } catch let error as DeepgramError {
            var state: CloudTranscriptionState = .retryableFailure
            var status: TranscriptionJobStatus = .retryableFailed
            var retryAfter: Date?
            var httpStatus: Int?
            var code: String?
            switch error {
            case .consentRequired:
                state = .consentBlocked; status = .consentBlocked
            case .missingAPIKey, .spendLimitExceeded, .actionRequired, .creditExhausted:
                state = .actionRequired; status = .actionRequired
                if case .actionRequired(let http, let providerCode) = error { httpStatus = http; code = providerCode }
                if case .creditExhausted = error { httpStatus = 402 }
                if case .missingAPIKey = error { code = "missing_api_key" }
                // Running out of money is the one failure Gabriel cannot discover
                // by waiting, so it raises an alert rather than only a job state.
                await DeepgramCreditMonitor.handle(error)
            case .ambiguousBilling:
                state = .ambiguousBilling; status = .ambiguousBilling
            case .retryable(let http, let date, _):
                retryAfter = date; httpStatus = http
            case .invalidResponse:
                state = .actionRequired; status = .actionRequired
            }
            let message = error.localizedDescription
            if state == .retryableFailure, job.attemptCount < 5 {
                status = .queued
                if retryAfter == nil {
                    let exponential = min(300.0, pow(2.0, Double(max(0, job.attemptCount - 1))) * 5.0)
                    retryAfter = Date().addingTimeInterval(exponential + Double.random(in: 0...2))
                }
            } else if state == .retryableFailure {
                state = .actionRequired; status = .actionRequired
            }
            job.status = status
            job.lastError = message
            job.cloud = .init(state: state, requestFingerprint: job.cloud?.requestFingerprint ?? "pending-audio-hash",
                              estimatedCostUSD: estimate, requestID: nil, retryAfter: retryAfter,
                              lastHTTPStatus: httpStatus, lastErrorCode: code, updatedAt: Date())
            session.transcriptionJob = job
            session.transcriptStatus = .failed
            session.save(); notifyRecordingChanged()
            // Persist the definite rejection before evaluating fallback. The
            // provider has already exhausted its configured Deepgram credentials.
            if CloudFallbackPolicy.fallback(preference: preference, failedEngine: .deepgram,
                                             error: error, availability: cloudAvailability(),
                                             checkpoint: job.cloud) == .speechmatics {
                job.status = .running
                job.lastError = nil
                session.transcriptionJob = job
                session.transcriptStatus = .inProgress
                return await transcribeSpeechmatics(session: session, prior: prior)
            }
            if status == .queued, let retryAfter {
                scheduleCloudRetry(sessionID: session.id, after: max(0, retryAfter.timeIntervalSinceNow))
            }
            // The prior transcript remains active on disk. Returning nil keeps
            // downstream notes/reports from being regenerated from a failure.
            _ = prior
            return nil
        } catch {
            return markJobFailed(session: session, message: TranscriptionErrorSanitizer.message(error))
        }
    }

    private static func transcribeSpeechmatics(
        session initial: RecordingSession,
        prior: Transcript
    ) async -> (session: RecordingSession, transcript: Transcript)? {
        var session = initial
        let audioURL = session.playbackURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return markJobFailed(session: session, message: "No mixed recording audio is available for Speechmatics.")
        }
        var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
        let checkpointRegion = job.cloud?.providerRegion.flatMap(SpeechmaticsRegion.init(rawValue:))
        guard let region = checkpointRegion ?? AppPreferences.speechmaticsRegion else {
            return markJobFailed(session: session, message: SpeechmaticsError.regionRequired.localizedDescription)
        }
        let assetDuration = (try? await AVURLAsset(url: audioURL).load(.duration)).map(CMTimeGetSeconds) ?? 0
        let duration = assetDuration.isFinite && assetDuration > 0
            ? assetDuration : max(0, (session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
        let estimate = SpeechmaticsConfiguration.estimatedCostUSD(duration: duration)
        let existingJobID = job.cloud?.provider == .speechmatics ? job.cloud?.providerJobID : nil
        job.cloud = .init(state: existingJobID == nil ? .uploading : .awaitingResponse,
                          requestFingerprint: job.cloud?.requestFingerprint ?? "pending-audio-hash",
                          estimatedCostUSD: estimate, requestID: existingJobID,
                          retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil,
                          updatedAt: Date(), provider: .speechmatics,
                          phase: existingJobID == nil ? .submitting : .polling,
                          providerJobID: existingJobID, providerRegion: region.rawValue)
        session.transcriptionJob = job

        do {
            // Submission uncertainty must survive a crash before any paid upload.
            try session.persist()
            notifyRecordingChanged()
            let provider = SpeechmaticsTranscriptionProvider(
                configuration: .init(region: region), rawResponseDirectory: session.folderURL,
                duration: duration, responseCache: AppPaths.speechmaticsResponseCacheDir)
            var replacement = try await provider.transcribe(
                fileURL: audioURL, sessionID: session.id, track: "mixed",
                existingJobID: existingJobID,
                onJobCreated: { jobID in try persistSpeechmaticsJobID(sessionID: session.id, jobID: jobID) })

            // Pull the job-ID checkpoint written by the callback into the final
            // atomic completion update.
            if let persisted = RecordingStore.allSessions().first(where: { $0.id == session.id }) {
                session = persisted
                job = persisted.transcriptionJob ?? job
            }
            replacement.status = .completed
            job.status = .completed
            job.completedAt = Date()
            job.lastError = nil
            let jobID = replacement.providerMetadata?.requestID ?? job.cloud?.providerJobID
            job.cloud = .init(state: .completed,
                              requestFingerprint: replacement.providerMetadata?.audioSHA256 ?? "unknown",
                              estimatedCostUSD: estimate, requestID: jobID, retryAfter: nil,
                              lastHTTPStatus: 200, lastErrorCode: nil, updatedAt: Date(),
                              provider: .speechmatics, phase: .completed, providerJobID: jobID)
            job.cloud?.providerRegion = region.rawValue
            session.transcriptionJob = job
            session.transcriptStatus = .completed
            session.localeUsed = replacement.localeUsed
            TranscriptStore.save(replacement, to: session)
            session.save(); notifyRecordingChanged()
            return (session, replacement)
        } catch let error as SpeechmaticsError {
            if let persisted = RecordingStore.allSessions().first(where: { $0.id == session.id }) {
                session = persisted
                job = persisted.transcriptionJob ?? job
            }
            var state: CloudTranscriptionState = .actionRequired
            var status: TranscriptionJobStatus = .actionRequired
            var phase: CloudTranscriptionPhase = .actionRequired
            var retryAfter: Date?
            var httpStatus: Int?
            switch error {
            case .consentRequired:
                state = .consentBlocked; status = .consentBlocked
            case .ambiguousSubmission:
                state = .ambiguousBilling; status = .ambiguousBilling; phase = .ambiguousSubmission
            case .retryable(let http, let date, _):
                state = .retryableFailure; status = .retryableFailed
                retryAfter = date; httpStatus = http
                phase = job.cloud?.providerJobID == nil ? .actionRequired : .polling
            case .actionRequired(let http, _):
                httpStatus = http
            case .missingAPIKey, .regionRequired, .modelTrainingConfirmationRequired,
                 .spendLimitExceeded, .rejected, .invalidResponse:
                break
            }
            if state == .retryableFailure, job.attemptCount < 5 {
                status = .queued
                if retryAfter == nil {
                    let exponential = min(300.0, pow(2.0, Double(max(0, job.attemptCount - 1))) * 5.0)
                    retryAfter = Date().addingTimeInterval(exponential + Double.random(in: 0...2))
                }
            } else if state == .retryableFailure {
                state = .actionRequired; status = .actionRequired; phase = .actionRequired
            }
            job.status = status
            job.lastError = error.localizedDescription
            job.cloud = .init(state: state,
                              requestFingerprint: job.cloud?.requestFingerprint ?? "pending-audio-hash",
                              estimatedCostUSD: estimate, requestID: job.cloud?.providerJobID,
                              retryAfter: retryAfter, lastHTTPStatus: httpStatus,
                              lastErrorCode: nil, updatedAt: Date(), provider: .speechmatics,
                              phase: phase, providerJobID: job.cloud?.providerJobID)
            job.cloud?.providerRegion = region.rawValue
            session.transcriptionJob = job
            session.transcriptStatus = .failed
            session.save(); notifyRecordingChanged()
            if status == .queued, let retryAfter {
                scheduleCloudRetry(sessionID: session.id, after: max(0, retryAfter.timeIntervalSinceNow))
            }
            _ = prior
            return nil
        } catch {
            return markJobFailed(session: session, message: TranscriptionErrorSanitizer.message(error))
        }
    }

    private static func persistSpeechmaticsJobID(sessionID: UUID, jobID: String) throws {
        guard var session = RecordingStore.allSessions().first(where: { $0.id == sessionID }),
              var job = session.transcriptionJob else {
            throw CocoaError(.fileNoSuchFile)
        }
        job.cloud?.provider = .speechmatics
        job.cloud?.providerJobID = jobID
        job.cloud?.requestID = jobID
        job.cloud?.state = .awaitingResponse
        job.cloud?.phase = .polling
        job.cloud?.updatedAt = Date()
        session.transcriptionJob = job
        try session.persist()
        notifyRecordingChanged()
    }

    private static func scheduleCloudRetry(sessionID: UUID, after delay: TimeInterval) {
        scheduledCloudRetries[sessionID]?.cancel()
        scheduledCloudRetries[sessionID] = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(max(0, delay))) }
            catch { return }
            guard !Task.isCancelled else { return }
            scheduledCloudRetries[sessionID] = nil
            // An active recording defers this durable queue; the transition
            // back to idle wakes it again. Use the same serialized drain as launch.
            await resumeQueuedJobsWhenIdle()
        }
    }

    private static func availableTracks(for session: RecordingSession) -> [(track: String, url: URL)] {
        var tracks: [(String, URL)] = []
        if FileManager.default.fileExists(atPath: session.micURL.path) { tracks.append(("mic", session.micURL)) }
        if session.systemAudioFileName != nil, FileManager.default.fileExists(atPath: session.systemAudioURL.path) {
            tracks.append(("system", session.systemAudioURL))
        }
        return tracks
    }

    private static func markJobFailed(session initial: RecordingSession, message: String) -> (session: RecordingSession, transcript: Transcript)? {
        // The provider may already have saved a remote job ID while awaiting
        // network or disk I/O. Never overwrite it with the pre-upload snapshot.
        var session = RecordingStore.allSessions().first(where: { $0.id == initial.id }) ?? initial
        var job = session.transcriptionJob ?? .legacy(status: .failed)
        job.recordUnexpectedFailure(message)
        session.transcriptionJob = job
        session.transcriptStatus = .failed
        session.save(); notifyRecordingChanged()
        return nil
    }

    private static func updateVaultTranscriptStatus(session: RecordingSession, value: String) {
        guard let service = MeetingNoteService.make(), let notePath = session.notePath else { return }
        let pb = VaultPathBuilder(config: service.config)
        attemptVaultUpdate("transcript_status frontmatter") {
            try VaultWriter(vaultURL: service.vaultURL).updateFrontmatter(relativePath: notePath,
                key: "transcript_status", value: value, pathBuilder: pb)
        }
    }

    /// Preserve diarized turns from either cloud provider in Obsidian notes.
    /// Anonymous speaker IDs remain zero-based in storage and display from one.
    private static func transcriptBody(_ transcript: Transcript) -> String {
        if transcript.segments.contains(where: { $0.speaker != nil }) {
            return transcript.segments.map { segment in
                let label = segment.speaker.map { "**Speaker \($0 + 1):**" } ?? "**Speaker:**"
                return "\(label) \(segment.text)"
            }.joined(separator: "\n\n")
        }
        let hasSystem = transcript.segments.contains { $0.track == "system" }
        guard hasSystem else { return transcript.plainText.isEmpty ? "_(no speech recognized)_" : transcript.plainText }
        return transcript.segments.map { "\($0.track == "mic" ? "**You:**" : "**Other audio:**") \($0.text)" }
            .joined(separator: "\n\n")
    }

    private static func notifyRecordingChanged() {
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
    }

    private static func attemptVaultUpdate(_ label: String, _ body: () throws -> Void) {
        do { try body() } catch { Log.obsidian.error("\(label, privacy: .public) failed: \(error, privacy: .public)") }
    }
}

/// Serializes job + transcript checkpoints. Every completed chunk first lands in
/// transcript.json and session.json before recognition proceeds to the next one.
private actor TranscriptionCheckpointPersistence {
    private var session: RecordingSession
    private var transcript: Transcript

    init(session: RecordingSession, transcript: Transcript) {
        self.session = session
        self.transcript = transcript
    }

    func track(named name: String) -> TranscriptionTrackProgress? {
        session.transcriptionJob?.tracks.first { $0.track == name }
    }

    func segments(for track: String) -> [TranscriptSegment] { transcript.segments.filter { $0.track == track } }
    func completedChunks(for track: String) -> Set<Int> {
        session.transcriptionJob?.tracks.first { $0.track == track }?.completedChunkIndexes ?? []
    }

    func beginTrack(_ track: String, fileName: String) {
        mutateTrack(track, fileName: fileName) { value in
            value.status = .running
            value.lastError = nil
        }
        persist()
    }

    func configure(track: String, chunks: [(index: Int, offset: TimeInterval)]) {
        mutateTrack(track, fileName: "") { $0.configureChunks(chunks) }
        persist()
    }

    func checkpoint(track: String, checkpoint: LocalTranscriptionProvider.Checkpoint) {
        mutateTrack(track, fileName: "") { $0.markCompleted(checkpoint.chunkIndex) }
        transcript.segments.removeAll { $0.track == track }
        transcript.segments.append(contentsOf: checkpoint.segments)
        transcript.segments.sort { $0.start < $1.start }
        TranscriptStore.save(transcript, to: session)
        persist()
    }

    func checkpoint(track: String, segments: [TranscriptSegment]) {
        mutateTrack(track, fileName: "") { value in
            value.chunks = [TranscriptionChunkProgress(index: 0, offset: 0, completed: true)]
        }
        transcript.segments.removeAll { $0.track == track }
        transcript.segments.append(contentsOf: segments)
        transcript.segments.sort { $0.start < $1.start }
        TranscriptStore.save(transcript, to: session)
        persist()
    }

    func complete(track: String, locale: String, source: String) {
        mutateTrack(track, fileName: "") { $0.status = .completed }
        transcript.localeUsed = locale
        transcript.source = source
        persist()
    }

    func fail(track: String, message: String) {
        mutateTrack(track, fileName: "") {
            $0.status = .failed
            $0.lastError = message
        }
        persist()
    }

    func snapshot() -> (session: RecordingSession, transcript: Transcript) { (session, transcript) }

    private func mutateTrack(_ name: String, fileName: String, _ body: (inout TranscriptionTrackProgress) -> Void) {
        guard var job = session.transcriptionJob else { return }
        let index: Int
        if let existing = job.tracks.firstIndex(where: { $0.track == name }) { index = existing }
        else {
            job.tracks.append(TranscriptionTrackProgress(track: name, fileName: fileName, status: .queued,
                                                         chunks: [], lastError: nil))
            index = job.tracks.count - 1
        }
        body(&job.tracks[index])
        session.transcriptionJob = job
    }

    private func persist() {
        session.save()
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
    }
}
