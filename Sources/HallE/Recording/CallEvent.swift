import Foundation

/// Builds a synthetic `UnifiedEvent` for a WhatsApp call (no calendar event, no
/// DB row). The project is filled in after transcription by classifying the
/// transcript, so no contact needs to be chosen up front.
enum CallEvent {
    /// `dedupKey` uses a `whatsapp:` namespace `EventDeduplicator` never emits.
    static func makeWhatsAppCall(at date: Date = Date()) -> UnifiedEvent {
        UnifiedEvent(
            dedupKey: "whatsapp:\(Int(date.timeIntervalSince1970))",
            title: "Llamada de WhatsApp — \(HalleDate.time(date))",
            startTs: date, endTs: date, isAllDay: false, status: "confirmed",
            effectiveResponse: nil, meetingURL: nil, location: nil, descriptionText: nil,
            htmlLink: nil, organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
            winnerAccountEmail: AppPreferences.primaryAccountEmail ?? "", projectId: nil,
            projectConfidence: nil, sourcesJSON: "[]")
    }
}
