import AppKit
import Foundation
import Observation

enum ProxyMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case http
    case socks5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Système (VPN / proxy OS)"
        case .http: return "Proxy HTTP"
        case .socks5: return "Proxy SOCKS5"
        }
    }
}

enum HLSQualityPreference: String, CaseIterable, Identifiable, Sendable {
    case best
    case ask

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Meilleure qualité automatiquement"
        case .ask: return "Choisir à chaque téléchargement"
        }
    }
}

/// Snapshot Sendable pour la download queue / URLSession.
struct SettingsSnapshot: Sendable {
    var downloadsRoot: URL
    var maxConcurrentJobs: Int
    var maxConcurrentSegments: Int
    var maxRetries: Int
    var proxyMode: ProxyMode
    var proxyHost: String
    var proxyPort: Int
    var proxyUsername: String
    var proxyPassword: String
    var hlsQuality: HLSQualityPreference
    var exportNamingTemplate: String

    var partsRoot: URL {
        downloadsRoot.appendingPathComponent(".parts", isDirectory: true)
    }

    func partsDirectory(forJobID id: UUID) -> URL {
        partsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func makeURLSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        // Aligner le plafond HTTP avec la concurrence segments (hosts CDN)
        config.httpMaximumConnectionsPerHost = max(8, maxConcurrentSegments)
        config.waitsForConnectivity = true

        switch proxyMode {
        case .system:
            config.connectionProxyDictionary = nil
        case .http, .socks5:
            let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, proxyPort > 0 else {
                config.connectionProxyDictionary = nil
                break
            }
            var proxy: [AnyHashable: Any] = [:]
            if proxyMode == .http {
                proxy[kCFNetworkProxiesHTTPEnable] = true
                proxy[kCFNetworkProxiesHTTPProxy] = host
                proxy[kCFNetworkProxiesHTTPPort] = proxyPort
                proxy[kCFNetworkProxiesHTTPSEnable] = true
                proxy[kCFNetworkProxiesHTTPSProxy] = host
                proxy[kCFNetworkProxiesHTTPSPort] = proxyPort
            } else {
                proxy[kCFProxyTypeKey] = kCFProxyTypeSOCKS
                proxy["SOCKSEnable"] = 1
                proxy["SOCKSProxy"] = host
                proxy["SOCKSPort"] = proxyPort
            }
            if !proxyUsername.isEmpty {
                proxy[kCFProxyUsernameKey] = proxyUsername
                proxy[kCFProxyPasswordKey] = proxyPassword
            }
            config.connectionProxyDictionary = proxy
        }

        return URLSession(configuration: config)
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let bookmark = "downloadFolderBookmark"
        static let maxJobs = "maxConcurrentJobs"
        static let maxSegments = "maxConcurrentSegments"
        static let proxyMode = "proxyMode"
        static let proxyHost = "proxyHost"
        static let proxyPort = "proxyPort"
        static let proxyUser = "proxyUsername"
        static let proxyPass = "proxyPassword"
        static let hlsQuality = "hlsQualityPreference"
        static let maxRetries = "downloadMaxRetries"
        static let vpnFilter = "vpnIndicatorFilter"
        static let autoHLS = "automationAutoEnqueueHLS"
        static let autoDASH = "automationAutoEnqueueDASH"
        static let autoProgressive = "automationAutoEnqueueProgressive"
        static let namingPreset = "exportNamingPreset"
        static let namingTemplate = "exportNamingTemplate"
    }

    private let defaults = UserDefaults.standard

    var downloadFolderPath: String = ""
    var maxConcurrentJobs: Int = 2
    var maxConcurrentSegments: Int = 16
    var proxyMode: ProxyMode = .system
    var proxyHost: String = ""
    var proxyPort: Int = 8080
    var proxyUsername: String = ""
    var proxyPassword: String = ""
    var hlsQuality: HLSQualityPreference = .best
    var maxRetries: Int = 3
    var vpnIndicatorFilter: VPNIndicatorFilter = .ignoreTailscale
    var automation = AutomationRules()
    var exportNamingPreset: ExportNamingPreset = .jellyfinMovie
    var exportNamingTemplate: String = ExportNamingPreset.jellyfinMovie.template

    private(set) var urlSession: URLSession = .shared

    init() {
        load()
        applyNetworkAndPaths()
    }

    static var defaultDownloadsRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
    }

    var downloadsRoot: URL {
        resolveBookmarkedFolder() ?? Self.defaultDownloadsRoot
    }

    var snapshot: SettingsSnapshot {
        SettingsSnapshot(
            downloadsRoot: downloadsRoot,
            maxConcurrentJobs: maxConcurrentJobs,
            maxConcurrentSegments: maxConcurrentSegments,
            maxRetries: maxRetries,
            proxyMode: proxyMode,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            proxyUsername: proxyUsername,
            proxyPassword: proxyPassword,
            hlsQuality: hlsQuality,
            exportNamingTemplate: resolvedNamingTemplate
        )
    }

    var resolvedNamingTemplate: String {
        switch exportNamingPreset {
        case .custom:
            let trimmed = exportNamingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? ExportNamingPreset.jellyfinMovie.template : trimmed
        default:
            return exportNamingPreset.template
        }
    }

    var namingPreviewPath: String {
        let sample = ExportNamingContext(
            title: "Inception",
            year: "2010",
            show: "Breaking Bad",
            season: "1",
            episode: "1",
            episodeTitle: "Pilot",
            kind: .progressive
        )
        return ExportNaming.relativePath(template: resolvedNamingTemplate, context: sample)
    }

    func load() {
        maxConcurrentJobs = max(1, defaults.integer(forKey: Keys.maxJobs) == 0 ? 2 : defaults.integer(forKey: Keys.maxJobs))
        let segments = defaults.object(forKey: Keys.maxSegments) as? Int
        maxConcurrentSegments = min(32, max(1, segments ?? 16))
        maxRetries = max(0, defaults.object(forKey: Keys.maxRetries) as? Int ?? 3)
        if let raw = defaults.string(forKey: Keys.proxyMode), let mode = ProxyMode(rawValue: raw) {
            proxyMode = mode
        }
        proxyHost = defaults.string(forKey: Keys.proxyHost) ?? ""
        let port = defaults.integer(forKey: Keys.proxyPort)
        proxyPort = port > 0 ? port : 8080
        proxyUsername = defaults.string(forKey: Keys.proxyUser) ?? ""
        proxyPassword = defaults.string(forKey: Keys.proxyPass) ?? ""
        if let raw = defaults.string(forKey: Keys.hlsQuality), let q = HLSQualityPreference(rawValue: raw) {
            hlsQuality = q
        }
        if let raw = defaults.string(forKey: Keys.vpnFilter), let f = VPNIndicatorFilter(rawValue: raw) {
            vpnIndicatorFilter = f
        }
        automation = AutomationRules(
            autoEnqueueHLS: defaults.bool(forKey: Keys.autoHLS),
            autoEnqueueDASH: defaults.bool(forKey: Keys.autoDASH),
            autoEnqueueProgressive: defaults.bool(forKey: Keys.autoProgressive)
        )
        if let raw = defaults.string(forKey: Keys.namingPreset),
           let preset = ExportNamingPreset(rawValue: raw)
        {
            exportNamingPreset = preset
        } else {
            exportNamingPreset = .jellyfinMovie
        }
        exportNamingTemplate = defaults.string(forKey: Keys.namingTemplate)
            ?? ExportNamingPreset.jellyfinMovie.template
        downloadFolderPath = downloadsRoot.path
    }

    func save() {
        defaults.set(maxConcurrentJobs, forKey: Keys.maxJobs)
        defaults.set(maxConcurrentSegments, forKey: Keys.maxSegments)
        defaults.set(maxRetries, forKey: Keys.maxRetries)
        defaults.set(proxyMode.rawValue, forKey: Keys.proxyMode)
        defaults.set(proxyHost.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.proxyHost)
        defaults.set(proxyPort, forKey: Keys.proxyPort)
        defaults.set(proxyUsername, forKey: Keys.proxyUser)
        defaults.set(proxyPassword, forKey: Keys.proxyPass)
        defaults.set(hlsQuality.rawValue, forKey: Keys.hlsQuality)
        defaults.set(vpnIndicatorFilter.rawValue, forKey: Keys.vpnFilter)
        defaults.set(automation.autoEnqueueHLS, forKey: Keys.autoHLS)
        defaults.set(automation.autoEnqueueDASH, forKey: Keys.autoDASH)
        defaults.set(automation.autoEnqueueProgressive, forKey: Keys.autoProgressive)
        defaults.set(exportNamingPreset.rawValue, forKey: Keys.namingPreset)
        defaults.set(resolvedNamingTemplate, forKey: Keys.namingTemplate)
        if exportNamingPreset == .custom {
            defaults.set(exportNamingTemplate, forKey: Keys.namingTemplate)
        }
        applyNetworkAndPaths()
        AppPreferences.publish(snapshot)
        downloadFolderPath = downloadsRoot.path
        AppLog.app.info("Settings saved proxy=\(self.proxyMode.rawValue, privacy: .public)")
    }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Dossier d’enregistrement des MP4"
        panel.directoryURL = downloadsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Keys.bookmark)
            _ = url.startAccessingSecurityScopedResource()
            downloadFolderPath = url.path
            save()
        } catch {
            AppLog.app.error("Bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resetDownloadFolderToDefault() {
        defaults.removeObject(forKey: Keys.bookmark)
        downloadFolderPath = Self.defaultDownloadsRoot.path
        save()
    }

    func applyNetworkAndPaths() {
        urlSession = snapshot.makeURLSession()
        try? FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: snapshot.partsRoot, withIntermediateDirectories: true)
        AppPreferences.publish(snapshot)
    }

    @discardableResult
    func cleanupOrphanParts(excludingJobIDs: Set<UUID> = []) -> Int {
        let partsRoot = snapshot.partsRoot
        let fm = FileManager.default
        var removed = 0

        if let children = try? fm.contentsOfDirectory(
            at: partsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in children {
                if let id = UUID(uuidString: url.lastPathComponent), excludingJobIDs.contains(id) {
                    continue
                }
                try? fm.removeItem(at: url)
                removed += 1
            }
            if let left = try? fm.contentsOfDirectory(atPath: partsRoot.path), left.isEmpty {
                try? fm.removeItem(at: partsRoot)
            }
        }

        removed += scrubExportTransientFiles(under: downloadsRoot)
        return removed
    }

    /// Enlève `merged_tmp*`, `concat_list.txt`, `.__os_*` dans l’arbre d’export (hors `.parts`).
    @discardableResult
    func scrubExportTransientFiles(under root: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var directories: [URL] = [root]
        while let item = enumerator.nextObject() as? URL {
            if item.path.contains("/.parts/") || item.lastPathComponent == ".parts" {
                enumerator.skipDescendants()
                continue
            }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                directories.append(item)
            }
        }

        var before = 0
        for dir in directories {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            before += names.filter { Self.isTransientExportFileName($0) }.count
            MediaAssembler.scrubTransientFiles(in: dir)
        }
        return before
    }

    private static func isTransientExportFileName(_ name: String) -> Bool {
        name == "concat_list.txt"
            || name == ".__concat_list.txt"
            || name.hasPrefix("merged_tmp")
            || name.hasPrefix(".__merged_tmp")
            || name.hasPrefix(".__os_")
    }

    private func resolveBookmarkedFolder() -> URL? {
        guard let data = defaults.data(forKey: Keys.bookmark) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if isStale,
           let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            defaults.set(refreshed, forKey: Keys.bookmark)
        }
        return url
    }
}

/// Accès thread-safe depuis DownloadQueue (snapshot publié).
enum AppPreferences {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var snapshot = SettingsSnapshot(
            downloadsRoot: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                .appendingPathComponent("OpenStream", isDirectory: true),
            maxConcurrentJobs: 2,
            maxConcurrentSegments: 16,
            maxRetries: 3,
            proxyMode: .system,
            proxyHost: "",
            proxyPort: 8080,
            proxyUsername: "",
            proxyPassword: "",
            hlsQuality: .best,
            exportNamingTemplate: ExportNamingPreset.jellyfinMovie.template
        )
    }

    private static let box = Box()

    static func publish(_ snapshot: SettingsSnapshot) {
        box.lock.lock()
        box.snapshot = snapshot
        box.lock.unlock()
    }

    static var current: SettingsSnapshot {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.snapshot
    }

    static var downloadsRoot: URL { current.downloadsRoot }
    static var exportRoot: URL { current.downloadsRoot }
    static var partsRoot: URL { current.partsRoot }

    static func partsDirectory(forJobID id: UUID) -> URL {
        current.partsDirectory(forJobID: id)
    }
}
