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
}
