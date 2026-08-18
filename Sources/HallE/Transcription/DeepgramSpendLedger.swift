import Foundation

struct DeepgramSpendEntry: Codable, Equatable {
    var fingerprint: String
    var month: String
    var estimatedUSD: Double
    var state: String
    var requestID: String?
    var updatedAt: Date
}

struct DeepgramSpendLedgerDocument: Codable, Equatable {
    var schemaVersion = 1
    var entries: [DeepgramSpendEntry] = []
}

enum DeepgramSpendLedger {
    static func authorize(estimateUSD: Double, fingerprint: String, now: Date = Date()) throws {
        var ledger = load()
        let month = monthKey(now)
        if ledger.entries.contains(where: { $0.fingerprint == fingerprint && $0.state != "failed" }) { return }
        let projected = ledger.entries.filter { $0.month == month && ["reserved", "completed", "ambiguous"].contains($0.state) }
            .reduce(estimateUSD) { $0 + $1.estimatedUSD }
        let limit = AppPreferences.deepgramMonthlyLimitUSD
        guard projected <= limit else { throw DeepgramError.spendLimitExceeded(projected: projected, limit: limit) }
        ledger.entries.append(.init(fingerprint: fingerprint, month: month, estimatedUSD: estimateUSD,
                                    state: "reserved", requestID: nil, updatedAt: now))
        save(ledger)
    }

    static func complete(estimateUSD: Double, fingerprint: String, requestID: String?, now: Date = Date()) {
        var ledger = load()
        if let index = ledger.entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
            ledger.entries[index].state = "completed"
            ledger.entries[index].requestID = requestID
            ledger.entries[index].updatedAt = now
        } else {
            ledger.entries.append(.init(fingerprint: fingerprint, month: monthKey(now), estimatedUSD: estimateUSD,
                                        state: "completed", requestID: requestID, updatedAt: now))
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

    static func load(url: URL = AppPaths.deepgramSpendLedgerFile) -> DeepgramSpendLedgerDocument {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(DeepgramSpendLedgerDocument.self, from: data) else { return .init() }
        return value
    }

    static func save(_ ledger: DeepgramSpendLedgerDocument, url: URL = AppPaths.deepgramSpendLedgerFile) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func monthKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Santiago"); formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}
