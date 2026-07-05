import Foundation

/// Stateless REST client for the Google Calendar API v3 over URLSession.
/// Access tokens come from `TokenStore`; handles one 401-refresh-retry and
/// surfaces rate-limit info for the caller's backoff.
struct GoogleCalendarAPI {
    let email: String
    let tokenStore: TokenStore

    enum APIError: Error, LocalizedError {
        case http(Int, String)
        case rateLimited(retryAfter: TimeInterval?)
        case decoding(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .http(let c, let m): "Calendar API HTTP \(c): \(m)"
            case .rateLimited: "Calendar API rate limited."
            case .decoding(let m): "Failed to decode calendar response: \(m)"
            case .network(let m): "Network error: \(m)"
            }
        }
    }

    private let base = "https://www.googleapis.com/calendar/v3"

    // MARK: - Endpoints

    func calendarList() async throws -> [CalendarListEntry] {
        var entries: [CalendarListEntry] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "\(base)/users/me/calendarList")!
            comps.queryItems = [.init(name: "maxResults", value: "250")]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let resp: CalendarListResponse = try await get(comps.url!)
            entries.append(contentsOf: resp.items ?? [])
            pageToken = resp.nextPageToken
        } while pageToken != nil
        return entries
    }

    /// Windowed events for one calendar, expanded to single instances.
    func events(calendarId: String, timeMin: Date, timeMax: Date) async throws -> [GEvent] {
        var events: [GEvent] = []
        var pageToken: String?
        let iso = ISO8601DateFormatter()
        repeat {
            var comps = URLComponents(string: "\(base)/calendars/\(calendarId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarId)/events")!
            comps.queryItems = [
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "timeMin", value: iso.string(from: timeMin)),
                .init(name: "timeMax", value: iso.string(from: timeMax)),
                .init(name: "maxResults", value: "250"),
                .init(name: "showDeleted", value: "false"),
            ]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let resp: EventsResponse = try await get(comps.url!)
            events.append(contentsOf: resp.items ?? [])
            pageToken = resp.nextPageToken
        } while pageToken != nil
        return events
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ url: URL, retryOn401: Bool = true) async throws -> T {
        let token = try await tokenStore.accessToken(for: email)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("No HTTP response")
        }
        switch http.statusCode {
        case 200:
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw APIError.decoding(error.localizedDescription) }
        case 401 where retryOn401:
            await tokenStore.invalidate(email)
            return try await get(url, retryOn401: false)
        case 403, 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0) }
            throw APIError.rateLimited(retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, String(body.prefix(200)))
        }
    }
}
