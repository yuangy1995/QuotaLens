import Foundation
import Combine

struct ResetCreditHistoryEvent: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let occurredAt: Date
    var isUsed: Bool { ["used", "redeemed", "consumed"].contains(kind.lowercased()) }
    var title: String {
        switch kind.lowercased() {
        case "granted", "earned": return L10n.text("获得重置卡", "Reset card granted")
        case "used", "redeemed", "consumed": return L10n.text("使用重置卡", "Reset card used")
        case "expired": return L10n.text("重置卡到期", "Reset card expired")
        default: return kind
        }
    }
    enum CodingKeys: String, CodingKey { case id, kind; case occurredAt = "occurred_at" }
    init(id: String, kind: String, occurredAt: Date) { self.id = id; self.kind = kind; self.occurredAt = occurredAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(String.self, forKey: .kind)
        guard !id.isEmpty, !kind.isEmpty else { throw QueryAccountError.format }
        if let seconds = try? values.decode(Double.self, forKey: .occurredAt), seconds.isFinite {
            occurredAt = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        } else {
            occurredAt = try Self.date(values.decode(String.self, forKey: .occurredAt))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(occurredAt.timeIntervalSince1970, forKey: .occurredAt)
    }
    static func date(_ string: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) else { throw QueryAccountError.format }
        return date
    }
}

struct ResetCreditHistoryPage: Sendable {
    let events: [ResetCreditHistoryEvent]
    let asOf: Date
    let windowStart: Date
    let nextCursor: String?

    static func decode(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [Any],
              let asOf = root["as_of"] as? String,
              let start = root["window_start"] as? String else { throw QueryAccountError.format }
        let decoded = try JSONDecoder().decode([ResetCreditHistoryEvent].self,
            from: JSONSerialization.data(withJSONObject: events))
        return .init(events: decoded, asOf: try ResetCreditHistoryEvent.date(asOf),
                     windowStart: try ResetCreditHistoryEvent.date(start),
                     nextCursor: (root["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

@MainActor
final class ResetCreditHistoryStore: ObservableObject {
    @Published private(set) var events: [ResetCreditHistoryEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var asOf: Date?
    @Published private(set) var windowStart: Date?
    @Published private(set) var nextCursor: String?
    private(set) var accountKey = ""
    private var generation = 0
    private var visitedCursors: Set<String> = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private struct Cache: Codable {
        let accountKey: String
        let events: [ResetCreditHistoryEvent]
        let asOf: Date
        let windowStart: Date
    }

    func load(accountKey key: String, append: Bool = false,
              fetch: (String?) async throws -> ResetCreditHistoryPage) async {
        guard !key.isEmpty else { clear(); return }
        guard !(loading && key == accountKey) else { return }
        let cursor = append ? nextCursor : nil
        if append, cursor == nil { return }
        generation += 1
        let request = generation
        if key != accountKey {
            events = []; asOf = nil; windowStart = nil; nextCursor = nil; visitedCursors = []
            if let data = defaults.data(forKey: "QuotaLens.resetHistory." + key),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.accountKey == key {
                events = cache.events; asOf = cache.asOf; windowStart = cache.windowStart
            }
        }
        accountKey = key
        loading = true
        error = nil
        defer { if request == generation { loading = false } }
        do {
            let page = try await fetch(cursor)
            guard request == generation, !Task.isCancelled else { return }
            var merged = append ? Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }) : [:]
            for event in page.events { merged[event.id] = event }
            events = merged.values.sorted { $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt }
            asOf = page.asOf
            windowStart = page.windowStart
            if !append { visitedCursors = [] }
            if let cursor { visitedCursors.insert(cursor) }
            nextCursor = page.nextCursor.flatMap { visitedCursors.contains($0) ? nil : $0 }
            defaults.set(try JSONEncoder().encode(Cache(accountKey: key, events: events,
                asOf: page.asOf, windowStart: page.windowStart)), forKey: "QuotaLens.resetHistory." + key)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            self.error = L10n.text("历史读取失败，保留上次结果。", "History could not be loaded. The last result was retained.")
        }
    }
    private func clear() {
        generation += 1
        events = []; accountKey = ""; asOf = nil; windowStart = nil; nextCursor = nil; error = nil; loading = false
    }
}
