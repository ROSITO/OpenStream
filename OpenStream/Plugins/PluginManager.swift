import Foundation

/// Version d’API plugins — incrémenter uniquement en cas de breaking change.
enum OpenStreamPluginAPI {
    static let version = 1
}

protocol OpenStreamPlugin: Sendable {
    var id: String { get }
    var name: String { get }
    var version: String { get }
    /// Doit égaler `OpenStreamPluginAPI.version` pour être chargé.
    var apiVersion: Int { get }
}

/// Extension des heuristiques URL : accepte un candidat que le core ignorerait.
protocol MediaURLHintPlugin: OpenStreamPlugin {
    func shouldAcceptMediaURL(_ url: URL, mimeType: String?) -> Bool
}

enum PluginValidationError: Error, LocalizedError, Sendable {
    case incompatibleAPI(plugin: String, got: Int, expected: Int)
    case duplicateID(String)
    case invalidBundle(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleAPI(let plugin, let got, let expected):
            return "Plugin \(plugin) : API \(got) incompatible (attendu \(expected))"
        case .duplicateID(let id):
            return "Plugin déjà enregistré : \(id)"
        case .invalidBundle(let message):
            return "Bundle plugin invalide : \(message)"
        }
    }
}

/// Registre thread-safe des plugins (V2).
final class PluginManager: @unchecked Sendable {
    static let shared = PluginManager()

    private let lock = NSLock()
    private var pluginsByID: [String: any OpenStreamPlugin] = [:]
    private var hintPlugins: [any MediaURLHintPlugin] = []

    private init() {}

    var registeredIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pluginsByID.keys.sorted()
    }

    func register(_ plugin: any OpenStreamPlugin) throws {
        guard plugin.apiVersion == OpenStreamPluginAPI.version else {
            throw PluginValidationError.incompatibleAPI(
                plugin: plugin.id,
                got: plugin.apiVersion,
                expected: OpenStreamPluginAPI.version
            )
        }
        lock.lock()
        defer { lock.unlock() }
        if pluginsByID[plugin.id] != nil {
            throw PluginValidationError.duplicateID(plugin.id)
        }
        pluginsByID[plugin.id] = plugin
        if let hint = plugin as? any MediaURLHintPlugin {
            hintPlugins.append(hint)
        }
        AppLog.app.info("Plugin registered \(plugin.id, privacy: .public) v\(plugin.version, privacy: .public)")
    }

    func unregister(id: String) {
        lock.lock()
        defer { lock.unlock() }
        pluginsByID[id] = nil
        hintPlugins.removeAll { $0.id == id }
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        pluginsByID.removeAll()
        hintPlugins.removeAll()
    }

    /// Heuristique étendue : true si un plugin tip accepte l’URL.
    func shouldAcceptMediaURL(_ url: URL, mimeType: String?) -> Bool {
        lock.lock()
        let plugins = hintPlugins
        lock.unlock()
        for plugin in plugins {
            if plugin.shouldAcceptMediaURL(url, mimeType: mimeType) {
                return true
            }
        }
        return false
    }

    /// Charge les bundles `*.openstreamplugin` depuis un dossier (validation Info.plist).
    /// Note sandbox : seuls les bundles signés / embarqués sont réalistes en prod.
    func loadBundles(from directory: URL) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var loaded: [String] = []
        for url in items where url.pathExtension == "openstreamplugin" {
            do {
                try validateBundle(at: url)
                loaded.append(url.lastPathComponent)
                AppLog.app.info("Validated plugin bundle \(url.lastPathComponent, privacy: .public)")
            } catch {
                AppLog.app.error("Plugin bundle rejected: \(error.localizedDescription, privacy: .public)")
            }
        }
        return loaded
    }

    func validateBundle(at url: URL) throws {
        guard let bundle = Bundle(url: url) else {
            throw PluginValidationError.invalidBundle("impossible d’ouvrir \(url.lastPathComponent)")
        }
        let info = bundle.infoDictionary ?? [:]
        guard let api = info["OpenStreamPluginAPIVersion"] as? Int
                ?? (info["OpenStreamPluginAPIVersion"] as? NSNumber)?.intValue
        else {
            throw PluginValidationError.invalidBundle("OpenStreamPluginAPIVersion manquant")
        }
        guard api == OpenStreamPluginAPI.version else {
            throw PluginValidationError.incompatibleAPI(
                plugin: url.lastPathComponent,
                got: api,
                expected: OpenStreamPluginAPI.version
            )
        }
        guard info["CFBundleIdentifier"] is String else {
            throw PluginValidationError.invalidBundle("CFBundleIdentifier manquant")
        }
        // Chargement dynamique de classes externes : hors scope sandbox MVP ;
        // validation du manifeste suffit pour le contrat Phase 7.
    }

    func registerBuiltInPlugins() {
        let example = ExampleMediaHintPlugin()
        lock.lock()
        let already = pluginsByID[example.id] != nil
        lock.unlock()
        guard !already else { return }
        do {
            try register(example)
        } catch {
            AppLog.app.error("Built-in plugin failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Plugin exemple : accepte les URLs que le core ignore si elles portent le marqueur de démo.
/// Marqueurs : fragment `#openstream-media` ou chemin contenant `/__openstream_media__/`.
struct ExampleMediaHintPlugin: MediaURLHintPlugin {
    let id = "app.openstream.plugin.example-media-hint"
    let name = "Example Media Hint"
    let version = "1.0.0"
    let apiVersion = OpenStreamPluginAPI.version

    func shouldAcceptMediaURL(_ url: URL, mimeType: String?) -> Bool {
        if let fragment = url.fragment?.lowercased(), fragment.contains("openstream-media") {
            return true
        }
        let path = url.path.lowercased()
        if path.contains("/__openstream_media__/") {
            return true
        }
        return false
    }
}
