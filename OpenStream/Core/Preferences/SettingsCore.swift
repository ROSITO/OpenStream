import Foundation

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

/// Snapshot Sendable pour la download queue / URLSession / CLI headless.
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

    static func `default`(downloadsRoot: URL? = nil) -> SettingsSnapshot {
        let root = downloadsRoot
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
        return SettingsSnapshot(
            downloadsRoot: root,
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
}

/// Accès thread-safe depuis DownloadQueue / CLI (snapshot publié).
enum AppPreferences {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var snapshot = SettingsSnapshot.default()
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
