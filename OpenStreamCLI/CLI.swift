import AppKit
import Foundation

enum OpenStreamCLIApp {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            CLI.printUsage()
            exit(AgentExitCode.usage)
        }
        let flags = CLI.parseFlags(Array(args.dropFirst()))
        switch command {
        case "help", "-h", "--help":
            CLI.printUsage()
        case "inbox":
            print(CLI.Paths.inbox.path)
        case "ping":
            CLI.enqueueViaApp(.ping, url: nil, json: flags.json)
        case "download":
            await CLI.cmdDownload(flags: flags)
        case "fetch":
            await CLI.cmdFetch(flags: flags)
        case "season":
            await CLI.cmdSeason(flags: flags)
        case "status", "list":
            await CLI.cmdStatus(flags: flags)
        case "wait":
            await CLI.cmdWait(flags: flags)
        case "cancel":
            await CLI.cmdCancel(flags: flags)
        case "open":
            guard let raw = flags.positionals.first, let url = URL(string: raw) else {
                fputs("Usage: openstream-cli open <url>\n", stderr)
                exit(AgentExitCode.usage)
            }
            CLI.enqueueViaApp(.open, url: url, json: flags.json)
        default:
            fputs("Commande inconnue: \(command)\n", stderr)
            CLI.printUsage()
            exit(AgentExitCode.usage)
        }
    }
}

enum CLI {
    enum Paths {
        static var supportRoot: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("OpenStream", isDirectory: true)
        }

        static var cliStore: URL {
            supportRoot.appendingPathComponent("cli-store", isDirectory: true)
        }

        static var sharedStore: URL { supportRoot }

        static var inbox: URL {
            supportRoot.appendingPathComponent("inbox", isDirectory: true)
        }

        static var defaultDownloads: URL {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                .appendingPathComponent("OpenStream", isDirectory: true)
        }
    }

    struct Flags {
        var json = false
        var viaApp = false
        var sharedDB = false
        var detectOnly = false
        var autoDownload = false
        var listOnly = false
        var cookie: String?
        var referer: String?
        var userAgent = DownloadCredentials.default.userAgent
        var out: URL?
        var kind: ManifestKind?
        var title: String?
        var showName: String?
        var seasonNumber: Int?
        var timeout: TimeInterval = 45
        var quality: HLSQualityPreference = .best
        var positionals: [String] = []
    }

    enum LocalCommandKind: String, Codable {
        case download, open, ping
    }

    struct LocalCommand: Codable {
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

    static func printUsage() {
        print(
            """
            openstream-cli — agent / headless OpenStream

            Usage:
              openstream-cli download <url> [options]
              openstream-cli fetch <pageURL> [--detect-only|--auto-download] [options]
              openstream-cli season <pageURL> [--list-only|--auto-download] [options]
              openstream-cli status [jobId]
              openstream-cli list
              openstream-cli wait <jobId>
              openstream-cli cancel <jobId>
              openstream-cli ping | inbox | help

            Options:
              --json  --cookie <h>  --referer <u>  --user-agent <ua>
              --out <dir>  --kind hls|dash|mp4  --title <name>
              --show <name>  --season <n>
              --list-only  --detect-only  --auto-download
              --shared-db  --via-app  --timeout <sec>  --quality best|ask

            Exit: 0 ok · 2 usage · 3 réseau · 4 assemble · 5 introuvable · 6 annulé · 7 detect timeout
            """
        )
    }

    static func parseFlags(_ args: [String]) -> Flags {
        var flags = Flags()
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json": flags.json = true
            case "--via-app": flags.viaApp = true
            case "--shared-db": flags.sharedDB = true
            case "--detect-only": flags.detectOnly = true
            case "--auto-download": flags.autoDownload = true
            case "--list-only": flags.listOnly = true
            case "--cookie":
                i += 1; flags.cookie = arg(args, i)
            case "--referer":
                i += 1; flags.referer = arg(args, i)
            case "--user-agent":
                i += 1; if let v = arg(args, i) { flags.userAgent = v }
            case "--out":
                i += 1
                if let v = arg(args, i) { flags.out = URL(fileURLWithPath: v, isDirectory: true) }
            case "--kind":
                i += 1
                if let v = arg(args, i) {
                    switch v.lowercased() {
                    case "hls": flags.kind = .hls
                    case "dash": flags.kind = .dash
                    case "mp4", "progressive": flags.kind = .progressive
                    default: break
                    }
                }
            case "--title":
                i += 1; flags.title = arg(args, i)
            case "--show":
                i += 1; flags.showName = arg(args, i)
            case "--season":
                i += 1
                if let v = arg(args, i), let n = Int(v), n > 0 { flags.seasonNumber = n }
            case "--timeout":
                i += 1
                if let v = arg(args, i), let t = TimeInterval(v) { flags.timeout = t }
            case "--quality":
                i += 1
                if let v = arg(args, i), let q = HLSQualityPreference(rawValue: v) { flags.quality = q }
            default:
                if a.hasPrefix("-") {
                    fputs("Option inconnue: \(a)\n", stderr)
                    exit(AgentExitCode.usage)
                }
                flags.positionals.append(a)
            }
            i += 1
        }
        return flags
    }

    private static func arg(_ args: [String], _ index: Int) -> String? {
        args.indices.contains(index) ? args[index] : nil
    }

    static func enqueueViaApp(_ kind: LocalCommandKind, url: URL?, json: Bool) {
        let inbox = Paths.inbox
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let command = LocalCommand(kind: kind, url: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(command)
            let name = String(
                format: "%lld-%@.json",
                Int64(Date().timeIntervalSince1970 * 1000),
                command.id.uuidString
            )
            let file = inbox.appendingPathComponent(name)
            try data.write(to: file, options: [.atomic])
            AgentEvent.emit(
                AgentEvent(
                    event: .info,
                    message: "via-app \(kind.rawValue) → \(file.path)",
                    url: url?.absoluteString
                ),
                jsonMode: json
            )
        } catch {
            fputs("Erreur: \(error.localizedDescription)\n", stderr)
            exit(AgentExitCode.network)
        }
    }

    static func makeService(flags: Flags) throws -> HeadlessDownloadService {
        var settings = SettingsSnapshot.default(downloadsRoot: flags.out ?? Paths.defaultDownloads)
        if let out = flags.out { settings.downloadsRoot = out }
        AppPreferences.publish(settings)
        let storeDir = flags.sharedDB ? Paths.sharedStore : Paths.cliStore
        return try HeadlessDownloadService(storeDirectory: storeDir, settings: settings)
    }

    static func credentials(from flags: Flags) -> DownloadCredentials {
        DownloadCredentials(
            cookieHeader: flags.cookie,
            referer: flags.referer,
            userAgent: flags.userAgent
        )
    }

    static func cmdDownload(flags: Flags) async {
        guard let raw = flags.positionals.first,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme)
        else {
            fputs("Usage: openstream-cli download <url>\n", stderr)
            exit(AgentExitCode.usage)
        }
        if flags.viaApp {
            enqueueViaApp(.download, url: url, json: flags.json)
            exit(AgentExitCode.success)
        }
        let code = await runDownload(url: url, flags: flags, export: nil)
        exit(code)
    }

    /// Download synchrone sans `exit` (réutilisé par `season`).
    @discardableResult
    static func runDownload(
        url: URL,
        flags: Flags,
        export: ExportMetadata?,
        service: HeadlessDownloadService? = nil
    ) async -> Int32 {
        do {
            let svc = try await {
                if let service { return service }
                let created = try makeService(flags: flags)
                _ = try await created.bootstrap()
                return created
            }()
            let kind = flags.kind ?? HeadlessDownloadService.inferKind(from: url)
            let job = try await svc.enqueue(
                url: url,
                kind: kind,
                title: flags.title ?? export?.title,
                credentials: credentials(from: flags),
                outputDirectory: flags.out,
                export: export
            )
            AgentEvent.emit(HeadlessDownloadService.event(for: job), jsonMode: flags.json)
            let finished = try await svc.wait(id: job.id) { event in
                AgentEvent.emit(event, jsonMode: flags.json)
            }
            return HeadlessDownloadService.exitCode(for: finished)
        } catch {
            AgentEvent.emit(
                AgentEvent(event: .failed, message: error.localizedDescription, url: url.absoluteString),
                jsonMode: flags.json
            )
            return AgentExitCode.network
        }
    }

    static func cmdFetch(flags: Flags) async {
        guard let raw = flags.positionals.first,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            fputs("Usage: openstream-cli fetch <pageURL>\n", stderr)
            exit(AgentExitCode.usage)
        }
        let media: [DetectedMedia]
        do {
            media = try await fetchMedia(pageURL: url, timeout: flags.timeout)
        } catch {
            AgentEvent.emit(
                AgentEvent(event: .failed, message: error.localizedDescription, url: url.absoluteString),
                jsonMode: flags.json
            )
            exit(AgentExitCode.network)
        }

        if media.isEmpty {
            AgentEvent.emit(
                AgentEvent(
                    event: .failed,
                    message: "Aucun média détecté avant timeout",
                    url: url.absoluteString
                ),
                jsonMode: flags.json
            )
            exit(AgentExitCode.detectTimeout)
        }
        for item in media {
            let preferred = item.preferredVariant?.playlistURL ?? item.sourceURL
            AgentEvent.emit(
                AgentEvent(
                    event: .detected,
                    title: flags.title ?? item.displayTitle,
                    kind: item.kind.rawValue,
                    message: "detected",
                    url: preferred.absoluteString
                ),
                jsonMode: flags.json
            )
        }
        if flags.detectOnly || !flags.autoDownload {
            exit(AgentExitCode.success)
        }
        let first = pickBestDetected(media)
        let mediaURL = first.preferredVariant?.playlistURL ?? first.sourceURL
        var dlFlags = flags
        dlFlags.positionals = [mediaURL.absoluteString]
        dlFlags.kind = first.kind
        // --title gagne ; sinon titre page / contenu résolu (pas l’ID opaque du m3u8).
        dlFlags.title = flags.title ?? first.displayTitle
        dlFlags.referer = dlFlags.referer ?? url.absoluteString
        let code = await runDownload(url: mediaURL, flags: dlFlags, export: nil)
        exit(code)
    }

    /// Évite de télécharger un HLS audio-only (`index-a1`) quand une variante vidéo existe.
    static func pickBestDetected(_ media: [DetectedMedia]) -> DetectedMedia {
        func score(_ item: DetectedMedia) -> Int {
            let u = (item.preferredVariant?.playlistURL ?? item.sourceURL).absoluteString.lowercased()
            var s = 0
            if u.contains("index-v") || u.contains("_v1") || u.contains("/v1") { s += 50 }
            if u.contains("index-a1") || u.contains("_a1") || u.contains("/a1.") { s -= 40 }
            if u.contains(".m3u8") { s += 5 }
            if item.kind == .progressive { s += 10 }
            s += min(item.variants.count, 10)
            return s
        }
        return media.max(by: { score($0) < score($1) }) ?? media[0]
    }

    static func cmdSeason(flags: Flags) async {
        guard let raw = flags.positionals.first,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            fputs("Usage: openstream-cli season <pageURL> [--list-only|--auto-download]\n", stderr)
            exit(AgentExitCode.usage)
        }

        let episodes: [EpisodeRef]
        do {
            episodes = try await enumerateSeason(pageURL: url, flags: flags)
        } catch {
            AgentEvent.emit(
                AgentEvent(event: .failed, message: error.localizedDescription, url: url.absoluteString),
                jsonMode: flags.json
            )
            exit(AgentExitCode.network)
        }

        if episodes.isEmpty {
            AgentEvent.emit(
                AgentEvent(
                    event: .failed,
                    message: "Aucun épisode trouvé",
                    url: url.absoluteString
                ),
                jsonMode: flags.json
            )
            exit(AgentExitCode.detectTimeout)
        }

        for ep in episodes {
            AgentEvent.emit(
                AgentEvent(
                    event: .episode,
                    title: ep.displayTitle,
                    message: "episode",
                    url: ep.url.absoluteString,
                    show: ep.show,
                    season: ep.season,
                    episode: ep.episode
                ),
                jsonMode: flags.json
            )
        }

        let shouldDownload = flags.autoDownload && !flags.listOnly && !flags.detectOnly
        if !shouldDownload {
            AgentEvent.emit(
                AgentEvent(
                    event: .seasonDone,
                    completedUnits: episodes.count,
                    totalUnits: episodes.count,
                    message: "listed \(episodes.count) episodes",
                    url: url.absoluteString,
                    show: flags.showName ?? episodes.first?.show,
                    season: flags.seasonNumber ?? episodes.first?.season
                ),
                jsonMode: flags.json
            )
            exit(AgentExitCode.success)
        }

        let service: HeadlessDownloadService
        do {
            service = try makeService(flags: flags)
            _ = try await service.bootstrap()
        } catch {
            AgentEvent.emit(
                AgentEvent(event: .failed, message: error.localizedDescription, url: url.absoluteString),
                jsonMode: flags.json
            )
            exit(AgentExitCode.network)
        }

        var successCount = 0
        var lastCode: Int32 = AgentExitCode.network
        for (index, ep) in episodes.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
            let media: [DetectedMedia]
            do {
                media = try await fetchMedia(pageURL: ep.url, timeout: flags.timeout)
            } catch {
                AgentEvent.emit(
                    AgentEvent(
                        event: .failed,
                        title: ep.displayTitle,
                        message: error.localizedDescription,
                        url: ep.url.absoluteString,
                        show: ep.show,
                        season: ep.season,
                        episode: ep.episode
                    ),
                    jsonMode: flags.json
                )
                continue
            }
            guard !media.isEmpty else {
                AgentEvent.emit(
                    AgentEvent(
                        event: .failed,
                        title: ep.displayTitle,
                        message: "Aucun média détecté",
                        url: ep.url.absoluteString,
                        show: ep.show,
                        season: ep.season,
                        episode: ep.episode
                    ),
                    jsonMode: flags.json
                )
                continue
            }
            let first = pickBestDetected(media)
            let mediaURL = first.preferredVariant?.playlistURL ?? first.sourceURL
            AgentEvent.emit(
                AgentEvent(
                    event: .detected,
                    title: ep.displayTitle,
                    kind: first.kind.rawValue,
                    message: "detected",
                    url: mediaURL.absoluteString,
                    show: ep.show,
                    season: ep.season,
                    episode: ep.episode
                ),
                jsonMode: flags.json
            )

            var dlFlags = flags
            dlFlags.title = ep.displayTitle
            dlFlags.kind = first.kind
            // Page saison (pas l’embed) pour cookies / anti-hotlink.
            dlFlags.referer = url.absoluteString
            let export = ExportMetadata(
                title: ep.displayTitle,
                show: ep.show ?? flags.showName,
                season: ep.paddedSeason,
                episode: ep.paddedEpisode,
                episodeTitle: ep.title,
                namingPreset: .jellyfinSeries
            )
            let code = await runDownload(url: mediaURL, flags: dlFlags, export: export, service: service)
            lastCode = code
            if code == AgentExitCode.success {
                successCount += 1
            }
        }

        AgentEvent.emit(
            AgentEvent(
                event: .seasonDone,
                completedUnits: successCount,
                totalUnits: episodes.count,
                message: "downloaded \(successCount)/\(episodes.count)",
                url: url.absoluteString,
                show: flags.showName ?? episodes.first?.show,
                season: flags.seasonNumber ?? episodes.first?.season
            ),
            jsonMode: flags.json
        )
        if successCount == 0 {
            exit(lastCode == AgentExitCode.success ? AgentExitCode.network : lastCode)
        }
        exit(AgentExitCode.success)
    }

    private static func enumerateSeason(pageURL: URL, flags: Flags) async throws -> [EpisodeRef] {
        let showHint = flags.showName ?? flags.title
        let pathMatch = EpisodeEnumerator.parseWatchPath(pageURL)
        let season = flags.seasonNumber ?? pathMatch?.season ?? 1

        var collected: [EpisodeRef] = []

        // French Stream / DLE : catalogue `/data/eps_{newsid}.txt` (épisodes = embeds).
        let fsEps = await EpisodeEnumerator.fetchFrenchStreamEpisodes(
            pageURL: pageURL,
            season: season,
            show: showHint
        )
        if !fsEps.isEmpty {
            collected = fsEps
        }

        if pathMatch != nil {
            let probed = await EpisodeEnumerator.probeWatchSeason(
                pageURL: pageURL,
                season: season,
                show: showHint,
                maxEpisodes: EpisodeEnumerator.defaultMaxEpisodes
            )
            collected = EpisodeEnumerator.merge(probed, collected)
        }

        if collected.isEmpty {
            let domLinks = try await listEpisodeLinks(
                pageURL: pageURL,
                defaultSeason: season,
                showHint: showHint,
                timeout: flags.timeout
            )
            if !domLinks.isEmpty {
                let withShow = domLinks.map { ref -> EpisodeRef in
                    var r = ref
                    if r.show == nil { r.show = showHint }
                    if flags.seasonNumber != nil { r.season = season }
                    return r
                }
                collected = EpisodeEnumerator.merge(withShow, collected)
            }
        }

        if let showHint {
            collected = collected.map { ref in
                var r = ref
                if r.show == nil { r.show = showHint }
                return r
            }
        }
        return collected
    }

    @MainActor
    private static func fetchMedia(pageURL: URL, timeout: TimeInterval) async throws -> [DetectedMedia] {
        let session = HeadlessBrowserSession()
        return try await session.fetch(pageURL: pageURL, timeout: timeout)
    }

    @MainActor
    private static func listEpisodeLinks(
        pageURL: URL,
        defaultSeason: Int?,
        showHint: String?,
        timeout: TimeInterval
    ) async throws -> [EpisodeRef] {
        let session = HeadlessBrowserSession()
        return try await session.listEpisodeLinks(
            pageURL: pageURL,
            defaultSeason: defaultSeason,
            showHint: showHint,
            timeout: timeout
        )
    }

    static func cmdStatus(flags: Flags) async {
        do {
            let service = try makeService(flags: flags)
            _ = try await service.bootstrap()
            if let raw = flags.positionals.first, let id = UUID(uuidString: raw) {
                guard let job = await service.job(id: id) else {
                    fputs("Job introuvable\n", stderr)
                    exit(AgentExitCode.notFound)
                }
                AgentEvent.emit(HeadlessDownloadService.event(for: job), jsonMode: flags.json)
                exit(AgentExitCode.success)
            }
            for job in await service.list() {
                AgentEvent.emit(HeadlessDownloadService.event(for: job), jsonMode: flags.json)
            }
            exit(AgentExitCode.success)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(AgentExitCode.network)
        }
    }

    static func cmdWait(flags: Flags) async {
        guard let raw = flags.positionals.first, let id = UUID(uuidString: raw) else {
            fputs("Usage: openstream-cli wait <jobId>\n", stderr)
            exit(AgentExitCode.usage)
        }
        do {
            let service = try makeService(flags: flags)
            _ = try await service.bootstrap()
            let finished = try await service.wait(id: id) { event in
                AgentEvent.emit(event, jsonMode: flags.json)
            }
            exit(HeadlessDownloadService.exitCode(for: finished))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(AgentExitCode.network)
        }
    }

    static func cmdCancel(flags: Flags) async {
        guard let raw = flags.positionals.first, let id = UUID(uuidString: raw) else {
            fputs("Usage: openstream-cli cancel <jobId>\n", stderr)
            exit(AgentExitCode.usage)
        }
        do {
            let service = try makeService(flags: flags)
            _ = try await service.bootstrap()
            await service.cancel(id: id)
            AgentEvent.emit(
                AgentEvent(event: .cancelled, jobId: id.uuidString, message: "cancelled"),
                jsonMode: flags.json
            )
            exit(AgentExitCode.success)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(AgentExitCode.network)
        }
    }
}
