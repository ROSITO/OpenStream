import Foundation

/// Orchestration Flix : scan hubs → digest → pick.
enum FlixService {
    static let defaultMax = 8

    struct ScanResult: Sendable {
        var items: [FlixItem]
        var warnings: [String]
        var hubsOK: Int
        var hubsSkipped: Int
    }

    static func supportRoot(sharedDB: Bool, fallback: URL) -> URL {
        // Favoris + seen toujours sous Application Support/OpenStream.
        _ = sharedDB
        return fallback
    }

    static func scan(
        supportRoot: URL,
        since: Date? = nil,
        max: Int? = nil,
        session: URLSession = .shared
    ) async -> ScanResult {
        let bookmarks = SeasonResolver.loadBookmarks(supportRoot: supportRoot)
        let hubs = FlixRSS.hubs(from: bookmarks)
        var items: [FlixItem] = []
        var warnings: [String] = []
        var ok = 0
        var skipped = 0

        if hubs.isEmpty {
            warnings.append(FlixError.noHubs.localizedDescription)
            return ScanResult(items: [], warnings: warnings, hubsOK: 0, hubsSkipped: 0)
        }

        for hub in hubs {
            do {
                let hubItems = try await FlixRSS.fetchItems(hub: hub, session: session)
                if hubItems.isEmpty {
                    warnings.append("Flix: RSS vide pour \(hub.title)")
                    skipped += 1
                } else {
                    items.append(contentsOf: hubItems)
                    ok += 1
                }
            } catch let err as FlixError {
                warnings.append(err.localizedDescription)
                skipped += 1
            } catch {
                warnings.append("Flix: \(hub.title) — \(error.localizedDescription)")
                skipped += 1
            }
        }

        items = dedupe(items)
        items = sortByPubDateDesc(items)
        if let since {
            items = items.filter { item in
                guard let raw = item.pubDate, let d = parsePubDate(raw) else { return true }
                return d >= since
            }
        }
        if let max, max > 0, items.count > max {
            items = Array(items.prefix(max))
        }
        return ScanResult(items: items, warnings: warnings, hubsOK: ok, hubsSkipped: skipped)
    }

    /// Top N non-vus. Si `seen` vide et `autoBootstrap` → seed le head sans les exposer.
    static func digest(
        supportRoot: URL,
        max: Int = defaultMax,
        markSeen: Bool,
        autoBootstrapIfEmpty: Bool = true,
        session: URLSession = .shared
    ) async -> (digest: FlixDigest, warnings: [String], bootstrapped: Bool) {
        let scan = await scan(supportRoot: supportRoot, session: session)
        var seen = FlixStore.loadSeen(supportRoot: supportRoot)
        var bootstrapped = false

        if seen.isEmpty, autoBootstrapIfEmpty, !scan.items.isEmpty {
            let seed = scan.items.map(\.id)
            try? FlixStore.markSeen(seed, supportRoot: supportRoot)
            seen = FlixStore.loadSeen(supportRoot: supportRoot)
            bootstrapped = true
        }

        let fresh = scan.items.filter { !seen.contains($0.id) }
        let capped = Array(fresh.prefix(max > 0 ? max : defaultMax))
        var map: [String: FlixDigest.FlixDigestEntry] = [:]
        for (idx, item) in capped.enumerated() {
            let n = idx + 1
            map[String(n)] = FlixDigest.FlixDigestEntry(from: item, n: n)
        }
        let digest = FlixDigest(
            updated: isoNow(),
            count: capped.count,
            items: map
        )
        try? FlixStore.saveDigest(digest, supportRoot: supportRoot)
        if markSeen, !capped.isEmpty {
            try? FlixStore.markSeen(capped.map(\.id), supportRoot: supportRoot)
        }
        return (digest, scan.warnings, bootstrapped)
    }

    /// Marque le head RSS actuel comme vu (sans digérer).
    static func bootstrap(
        supportRoot: URL,
        session: URLSession = .shared
    ) async -> (marked: Int, warnings: [String]) {
        let scan = await scan(supportRoot: supportRoot, session: session)
        try? FlixStore.markSeen(scan.items.map(\.id), supportRoot: supportRoot)
        return (scan.items.count, scan.warnings)
    }

    static func pick(indices: [Int], supportRoot: URL) throws -> [FlixItem] {
        guard let digest = FlixStore.loadDigest(supportRoot: supportRoot) else {
            throw FlixError.pickMissing("pas de digest")
        }
        var out: [FlixItem] = []
        for n in indices {
            guard let entry = digest.items[String(n)] else {
                throw FlixError.pickMissing("\(n)")
            }
            out.append(entry.asItem)
        }
        return out
    }

    static func parsePickSpec(_ raw: String) throws -> [Int] {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
        var nums: [Int] = []
        for p in parts {
            let s = p.trimmingCharacters(in: .whitespaces)
            guard let n = Int(s), n > 0 else {
                throw FlixError.usage("pick: indices invalides « \(raw) »")
            }
            nums.append(n)
        }
        guard !nums.isEmpty else {
            throw FlixError.usage("Usage: openstream-cli flix pick <n|n,m>")
        }
        return nums
    }

    static func parseSince(_ raw: String) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("d"), let days = Int(trimmed.dropLast()), days >= 0 {
            return Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }
        throw FlixError.usage("--since: ISO-8601 ou Nd (ex. 7d)")
    }

    // MARK: - Helpers

    private static func dedupe(_ items: [FlixItem]) -> [FlixItem] {
        var seen = Set<String>()
        var out: [FlixItem] = []
        for item in items {
            if seen.insert(item.id).inserted {
                out.append(item)
            }
        }
        return out
    }

    private static func sortByPubDateDesc(_ items: [FlixItem]) -> [FlixItem] {
        items.sorted { a, b in
            let da = a.pubDate.flatMap(parsePubDate) ?? .distantPast
            let db = b.pubDate.flatMap(parsePubDate) ?? .distantPast
            return da > db
        }
    }

    static func parsePubDate(_ raw: String) -> Date? {
        let rf = DateFormatter()
        rf.locale = Locale(identifier: "en_US_POSIX")
        rf.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        if let d = rf.date(from: raw) { return d }
        rf.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = rf.date(from: raw) { return d }
        let iso = ISO8601DateFormatter()
        return iso.date(from: raw)
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}
