import Foundation

/// Prompt templates for each LLM task. Kept as code constants; structured inputs
/// are pre-rendered to compact JSON before substitution.
enum PromptTemplateStore {
    static func classification(input: ClassificationInput, candidates: [String]) -> (system: String, user: String) {
        let system = """
        You classify a work meeting into exactly one of the user's known projects, or null if none fit.
        Known projects: \(candidates.joined(separator: ", ")).
        Respond with ONLY a JSON object, no prose, no code fences, matching:
        {"project": string|null, "confidence": number 0..1, "reason": string, "suggested_obsidian_path": string, "requires_user_confirmation": boolean}
        "project" must be exactly one of the known project names or null. Never invent a project.
        """
        let payload: [String: Any] = [
            "title": input.title,
            "description": input.description ?? "",
            "attendees": input.attendeeEmails,
            "organizer": input.organizerEmail ?? "",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return (system, "Classify this meeting:\n\(json)")
    }

    static func summary(transcript: String, context: MeetingContext) -> (String, String) {
        let system = """
        You summarize a meeting transcript for the user's Obsidian notes. Be concise and factual.
        Write in the same language as the transcript. Respond with plain Markdown bullet points only.
        Do not invent content that isn't supported by the transcript.
        """
        return (system, "Meeting: \(context.title) (\(context.date))\n\nTranscript:\n\(transcript)")
    }

    static func decisions(transcript: String, context: MeetingContext) -> (String, String) {
        let system = """
        Extract the concrete DECISIONS made in this meeting transcript. Markdown bullets only, same
        language as the transcript. If none, respond with "- (no explicit decisions)".
        """
        return (system, "Transcript:\n\(transcript)")
    }

    static func actionItems(transcript: String, context: MeetingContext) -> (String, String) {
        let system = """
        Extract action items from the transcript. Respond with ONLY a JSON object:
        {"action_items": [{"task": string, "owner": string|null, "due_date": string|null, "project": string|null, "confidence": number 0..1}]}
        No prose, no code fences. If none, return {"action_items": []}.
        """
        return (system, "Project: \(context.project ?? "unknown")\nTranscript:\n\(transcript)")
    }

    static func cleanup(transcript: String) -> (String, String) {
        let system = """
        Clean up this raw speech-to-text transcript: fix punctuation, capitalization, and obvious
        recognition errors. Do NOT add, remove, or summarize content. Keep the same language.
        Respond with the cleaned transcript text only.
        """
        return (system, transcript)
    }

    static func dailyBrief(events: [BriefEventInput]) -> (String, String) {
        let system = """
        Write a short (max 5 lines) morning brief for the user's day from their meetings.
        Friendly, practical, no fluff. Same language as the meeting titles.
        """
        let lines = events.map { "\($0.time) \($0.title)\($0.project.map { " [\($0)]" } ?? "")" }.joined(separator: "\n")
        return (system, "Today's meetings:\n\(lines)")
    }

    static func meetingInsights(transcript: String, context: MeetingContext) -> (String, String) {
        let system = """
        Analyze a meeting transcript factually. Return ONLY JSON matching this shape:
        {"cleaned_transcript": string|null, "summary": string, "decisions": [string],
        "action_items": [{"task": string, "owner": string|null, "due_date": string|null,
        "project": string|null, "confidence": number|null}], "follow_ups": [string],
        "risks": [string], "confidence": number|null}
        Do not invent facts. Use the transcript's language. Keep summary concise.
        """
        return (system, "Meeting: \(context.title) (\(context.date))\nTranscript:\n\(transcript)")
    }

    /// Names a recording after its content. The reply becomes a folder name, so
    /// it has to be one short line — and it has to describe what was actually
    /// discussed rather than restate the calendar invite.
    static func recordingTopic(transcript: String, context: MeetingContext) -> (String, String) {
        let system = """
        You name a meeting recording after what was actually discussed.
        Reply with ONE line: a specific noun phrase of at most 8 words, in the transcript's language.
        No quotes, no trailing period, no prefix such as "Meeting about".
        Describe the real subject matter, not the calendar title, and never invent topics that
        the transcript does not support. If the transcript is too short or empty to tell,
        reply with exactly: UNKNOWN
        """
        let opening = String(transcript.prefix(24_000))
        return (system, "Scheduled title: \(context.title)\nDate: \(context.date)\n\nTranscript:\n\(opening)")
    }

    static func projectSnapshot(context: ProjectAssistantContext) -> (String, String) {
        let system = """
        You maintain a factual project operating brief. Use only the cited Hall-e context.
        Return ONLY JSON matching:
        {"summary":string,"status":string,"health":"on-track"|"at-risk"|"blocked"|"unknown",
        "goals":[string],"decisions":[string],"blockers":[string],"risks":[string],
        "next_steps":[string],"open_questions":[string],"agenda":[string],
        "citation_ids":[string],"confidence":number|null}
        Every material claim must be supported by one of the provided [S#] references. Distinguish
        confirmed facts from inferences by prefixing inferred items with "Inference:". Do not invent
        commitments, owners, deadlines, or progress. Use the dominant language of the context.
        """
        return (system, "Project: \(context.projectName)\n\n\(context.markdown)")
    }

    static func projectQuestion(_ question: String, context: ProjectAssistantContext) -> (String, String) {
        let system = """
        You are Hall-e's project assistant. Answer only from the cited project context. Be practical,
        concise, and explicit about uncertainty. Return ONLY JSON matching:
        {"answer":string,"citation_ids":[string],"suggested_updates":[string]}
        Cite source IDs such as [S1] in the answer. Suggested updates are derived guidance, never
        invented facts or commitments. Use the language of the question.
        """
        return (system, "Question: \(question)\n\nProject context:\n\(context.markdown)")
    }
}
