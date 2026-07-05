import Foundation

/// OAuth token endpoint response.
struct TokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

/// A token endpoint error (e.g. invalid_grant → account needs reauth).
struct OAuthErrorResponse: Codable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Calendar API DTOs

struct CalendarListResponse: Codable {
    let items: [CalendarListEntry]?
    let nextPageToken: String?
}

struct CalendarListEntry: Codable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let primary: Bool?
    let accessRole: String?
    let backgroundColor: String?
    let selected: Bool?
}

struct EventsResponse: Codable {
    let items: [GEvent]?
    let nextPageToken: String?
    let timeZone: String?
}

struct GEvent: Codable {
    let id: String
    let iCalUID: String?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let start: GEventDateTime?
    let end: GEventDateTime?
    let organizer: GEventPerson?
    let attendees: [GEventAttendee]?
    let originalStartTime: GEventDateTime?
    let updated: String?
    let etag: String?
    let conferenceData: GConferenceData?
    let recurringEventId: String?
}

struct GEventDateTime: Codable {
    let dateTime: String?   // RFC3339 with offset (timed events)
    let date: String?       // yyyy-MM-dd (all-day)
    let timeZone: String?
}

struct GEventPerson: Codable {
    let email: String?
    let displayName: String?
    let isSelf: Bool?
    enum CodingKeys: String, CodingKey {
        case email, displayName
        case isSelf = "self"
    }
}

struct GEventAttendee: Codable {
    let email: String?
    let displayName: String?
    let responseStatus: String?
    let organizer: Bool?
    let isSelf: Bool?
    let resource: Bool?
    let optional: Bool?
    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, resource, optional
        case isSelf = "self"
    }
}

struct GConferenceData: Codable {
    let entryPoints: [GEntryPoint]?
}

struct GEntryPoint: Codable {
    let entryPointType: String?  // "video", "phone", "more"
    let uri: String?
}
