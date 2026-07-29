import Foundation

enum BatchURLParser {
    /// Extrait les URLs http(s) d’un texte multi-lignes (une URL par ligne ou séparées par espaces).
    static func parse(_ text: String) -> [URL] {
        let tokens = text
            .replacingOccurrences(of: ",", with: "\n")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var urls: [URL] = []
        for token in tokens {
            let withScheme: String
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                withScheme = token
            } else if token.contains(".") {
                withScheme = "https://\(token)"
            } else {
                continue
            }
            guard let url = URL(string: withScheme),
                  url.scheme == "http" || url.scheme == "https",
                  url.host != nil
            else { continue }
            let key = url.absoluteString.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            urls.append(url)
        }
        return urls
    }

    static func classify(_ url: URL) -> MediaClassification {
        MediaDetector.classify(url: url, mimeType: nil)
    }

    static func partition(_ urls: [URL]) -> (media: [URL], pages: [URL]) {
        var media: [URL] = []
        var pages: [URL] = []
        for url in urls {
            switch classify(url) {
            case .hls, .dash, .progressive:
                media.append(url)
            case .segment, .unknown:
                pages.append(url)
            }
        }
        return (media, pages)
    }
}

struct AutomationRules: Sendable, Hashable, Codable {
    var autoEnqueueHLS: Bool = false
    var autoEnqueueDASH: Bool = false
    var autoEnqueueProgressive: Bool = false

    var isEnabled: Bool {
        autoEnqueueHLS || autoEnqueueDASH || autoEnqueueProgressive
    }

    func shouldAutoEnqueue(_ kind: ManifestKind) -> Bool {
        switch kind {
        case .hls: return autoEnqueueHLS
        case .dash: return autoEnqueueDASH
        case .progressive: return autoEnqueueProgressive
        }
    }
}

enum LocalCommandKind: String, Codable, Sendable {
    case download
    case open
    case ping
}

struct LocalCommand: Codable, Sendable, Identifiable {
    var id: UUID
    var kind: LocalCommandKind
    var url: URL?
    var createdAt: Date

    init(id: UUID = UUID(), kind: LocalCommandKind, url: URL? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.url = url
        self.createdAt = createdAt
    }
}

enum LocalCommandPaths {
    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
    }

    static var inbox: URL {
        supportRoot.appendingPathComponent("inbox", isDirectory: true)
    }

    static var processed: URL {
        supportRoot.appendingPathComponent("inbox-processed", isDirectory: true)
    }
}

/// File d’attente locale pour la CLI (`~/Library/Application Support/OpenStream/inbox/*.json`).
@MainActor
final class LocalCommandServer {
    private var timer: Timer?
    private let decoder = JSONDecoder()
    var onCommand: ((LocalCommand) -> Void)?

    func start() {
        try? FileManager.default.createDirectory(at: LocalCommandPaths.inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: LocalCommandPaths.processed, withIntermediateDirectories: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: LocalCommandPaths.inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let command = try decoder.decode(LocalCommand.self, from: data)
                onCommand?(command)
                let dest = LocalCommandPaths.processed.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: file, to: dest)
                AppLog.app.info("Local command \(command.kind.rawValue, privacy: .public)")
            } catch {
                AppLog.app.error("Inbox command failed: \(error.localizedDescription, privacy: .public)")
                try? fm.removeItem(at: file)
            }
        }
    }
}
