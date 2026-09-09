import Foundation

enum CloudTranscriptionSpendError: Error, Equatable {
    case limitExceeded(projected: Double, limit: Double)
}

struct CloudTranscriptionSpendEntry: Codable, Equatable {
    var fingerprint: String
    var month: String
    var estimatedUSD: Double
    var state: String
    var requestID: String?
    var updatedAt: Date
    var provider: CloudTranscriptionProvider
    var rateUSDPerHour: Double?
    var rateObservedAt: String?

    init(fingerprint: String, month: String, estimatedUSD: Double, state: String,
         requestID: String?, updatedAt: Date, provider: CloudTranscriptionProvider,
         rateUSDPerHour: Double? = nil, rateObservedAt: String? = nil) {
        self.fingerprint = fingerprint
        self.month = month
        self.estimatedUSD = estimatedUSD
        self.state = state
        self.requestID = requestID
        self.updatedAt = updatedAt
        self.provider = provider
        self.rateUSDPerHour = rateUSDPerHour
        self.rateObservedAt = rateObservedAt
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, month, estimatedUSD, state, requestID, updatedAt
        case provider, rateUSDPerHour, rateObservedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        month = try values.decode(String.self, forKey: .month)
        estimatedUSD = try values.decode(Double.self, forKey: .estimatedUSD)
        state = try values.decode(String.self, forKey: .state)
        requestID = try values.decodeIfPresent(String.self, forKey: .requestID)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // Schema v1 contained only Deepgram entries.
        provider = try values.decodeIfPresent(CloudTranscriptionProvider.self, forKey: .provider) ?? .deepgram
        rateUSDPerHour = try values.decodeIfPresent(Double.self, forKey: .rateUSDPerHour)
        rateObservedAt = try values.decodeIfPresent(String.self, forKey: .rateObservedAt)
    }
}

struct CloudTranscriptionSpendLedgerDocument: Codable, Equatable {
    var schemaVersion = 2
    var entries: [CloudTranscriptionSpendEntry] = []
}

enum CloudTranscriptionSpendLedger {
    static func authorize(provider: CloudTranscriptionProvider, estimateUSD: Double,
                          fingerprint: String, rateUSDPerHour: Double? = nil,
                          rateObservedAt: String? = nil, now: Date = Date()) throws {
        var ledger = load()
        let month = monthKey(now)
        if ledger.entries.contains(where: { $0.fingerprint == fingerprint && $0.state != "failed" }) { return }
        let projected = ledger.entries
            .filter { $0.month == month && ["reserved", "completed", "ambiguous"].contains($0.state) }
            .reduce(estimateUSD) { $0 + $1.estimatedUSD }
        let limit = AppPreferences.cloudTranscriptionMonthlyLimitUSD
        guard projected <= limit else {
            throw CloudTranscriptionSpendError.limitExceeded(projected: projected, limit: limit)
        }
        ledger.entries.append(.init(fingerprint: fingerprint, month: month, estimatedUSD: estimateUSD,
                                    state: "reserved", requestID: nil, updatedAt: now,
                                    provider: provider, rateUSDPerHour: rateUSDPerHour,
                                    rateObservedAt: rateObservedAt))
        save(ledger)
    }

    static func complete(provider: CloudTranscriptionProvider, estimateUSD: Double,
                         fingerprint: String, requestID: String?, now: Date = Date()) {
        var ledger = load()
        if let index = ledger.entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
            ledger.entries[index].state = "completed"
            ledger.entries[index].requestID = requestID
            ledger.entries[index].updatedAt = now
        } else {
            ledger.entries.append(.init(fingerprint: fingerprint, month: monthKey(now),
                                        estimatedUSD: estimateUSD, state: "completed",
                                        requestID: requestID, updatedAt: now, provider: provider))
        }
        save(ledger)
    }

    static func markAmbiguous(fingerprint: String, now: Date = Date()) {
        var ledger = load()
        guard let index = ledger.entries.firstIndex(where: { $0.fingerprint == fingerprint }) else { return }
        ledger.entries[index].state = "ambiguous"
        ledger.entries[index].updatedAt = now
        save(ledger)
    }

    static func load(url: URL = AppPaths.cloudTranscriptionSpendLedgerFile) -> CloudTranscriptionSpendLedgerDocument {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(CloudTranscriptionSpendLedgerDocument.self, from: data) else {
            return .init()
        }
        return value
    }

    static func save(_ ledger: CloudTranscriptionSpendLedgerDocument,
                     url: URL = AppPaths.cloudTranscriptionSpendLedgerFile) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func monthKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Santiago")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}
