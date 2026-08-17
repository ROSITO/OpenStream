import Observation
import Foundation

@MainActor
@Observable
final class AppState {
    let settings = AppSettings()
    let browser = BrowserController()
    let cookieBridge = CookieBridge()
    let networkObserver = NetworkObserver()
    let mediaCatalog: MediaCatalog
    let downloadManager: DownloadManager
    let vpnMonitor = SystemVPNMonitor()
    let bookmarks: BookmarkStore
    let history: DownloadHistoryStore
    let commandServer = LocalCommandServer()

    var selectedMediaID: DetectedMedia.ID?
    var selectedCandidateID: NetworkMediaCandidate.ID?
    var showRawCandidates: Bool = false
    var showDownloads: Bool = true
    var showSettings: Bool = false
    var showBookmarkManager: Bool = false
    var showHistory: Bool = false
    var showBatchSheet: Bool = false
    var ffmpegStatus: FFmpegSetup.Status = .missingFFmpeg
    var ffmpegInstallInProgress = false
    var ffmpegInstallLog: String?

    /// Média en attente de choix de variante HLS.
    var pendingVariantMedia: DetectedMedia?
    /// Pages restantes d’un batch (ouvertes une par une).
    private(set) var pendingBatchPages: [URL] = []
    private var awaitingBatchPageLoad = false
    /// Sources déjà auto-enqueued pour éviter les boucles.
    private var autoEnqueuedKeys = Set<String>()

    init() {
        bookmarks = BookmarkStore()
        history = DownloadHistoryStore()
        mediaCatalog = MediaCatalog(session: settings.urlSession)
        if let manager = try? DownloadManager() {
            downloadManager = manager
        } else {
            let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("OpenStreamStore", isDirectory: true)
            let store = try! DownloadJobStore(directory: storeDir)
            downloadManager = try! DownloadManager(queue: DownloadQueue(store: store))
        }
        downloadManager.historyStore = history

        mediaCatalog.attachCookieBridge(cookieBridge)
        mediaCatalog.onMediaDetected = { [weak self] media in
            self?.handleAutomatedDetection(media)
        }

        networkObserver.onCandidateAccepted = { [weak self] candidate in
            guard let self else { return }
            Task { @MainActor in
                let title = await self.browser.resolveContentTitle(
                    pageURL: candidate.pageURL,
                    mediaURL: candidate.url
                )
                self.mediaCatalog.ingest(candidate, pageTitle: title)
            }
        }

        browser.onMediaCandidate = { [weak self] candidate in
            self?.networkObserver.ingest(candidate)
        }
        browser.onWebViewReady = { [weak self] webView in
            guard let self else { return }
            self.cookieBridge.attach(to: webView)
            self.networkObserver.attachScriptMessaging(to: webView)
        }
        browser.onPageTitleChange = { [weak self] title in
            self?.mediaCatalog.refreshSuggestedTitles(using: title)
        }

        commandServer.onCommand = { [weak self] command in
            self?.handleLocalCommand(command)
        }

        NotificationCenter.default.addObserver(
            forName: .openStreamNavigationDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.cookieBridge.refreshSnapshot()
                self?.advanceBatchPagesIfNeeded()
            }
        }
    }

    func startServices() {
        PluginManager.shared.registerBuiltInPlugins()
        let pluginsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        _ = PluginManager.shared.loadBundles(from: pluginsDir)

        settings.applyNetworkAndPaths()
        mediaCatalog.updateSession(settings.urlSession)
        vpnMonitor.filter = settings.vpnIndicatorFilter
        vpnMonitor.start()
        let activeIDs = Set(downloadManager.jobs.map(\.id))
        let removed = settings.cleanupOrphanParts(excludingJobIDs: activeIDs)
        if removed > 0 {
            AppLog.app.info("Orphan parts cleaned: \(removed, privacy: .public)")
        }
        downloadManager.start()
        commandServer.start()
        refreshFFmpegStatus()
    }

    func refreshFFmpegStatus() {
        ffmpegStatus = FFmpegSetup.status()
        if case .ready = ffmpegStatus {
            ffmpegInstallLog = nil
        }
    }

    func installFFmpegWithBrew() {
        guard !ffmpegInstallInProgress else { return }
        ffmpegInstallInProgress = true
        ffmpegInstallLog = "Installation de FFmpeg via Homebrew…"
        Task {
            do {
                try await FFmpegSetup.installFFmpeg()
                refreshFFmpegStatus()
                ffmpegInstallLog = "FFmpeg installé."
            } catch {
                ffmpegInstallLog = error.localizedDescription
            }
            ffmpegInstallInProgress = false
        }
    }

    func applySettings() {
        settings.save()
        mediaCatalog.updateSession(settings.urlSession)
        vpnMonitor.filter = settings.vpnIndicatorFilter
        vpnMonitor.refresh()
    }

    var candidates: [NetworkMediaCandidate] {
        networkObserver.candidates
    }

    var detectedMedia: [DetectedMedia] {
        mediaCatalog.detected
    }

    func clearMedia() {
        networkObserver.clear()
        mediaCatalog.clear()
        selectedMediaID = nil
        selectedCandidateID = nil
        autoEnqueuedKeys.removeAll()
    }

    func enqueueSelectedOr(_ media: DetectedMedia) {
        // Toujours proposer le nom de fichier (le titre de page est souvent faux : site, onglet, etc.)
        pendingVariantMedia = media
    }

    func startDownload(
        media: DetectedMedia,
        variant: MediaVariant?,
        audioTrack: MediaTrack? = nil,
        subtitleTrack: MediaTrack? = nil,
        metadata: ExportMetadata? = nil
    ) {
        pendingVariantMedia = nil
        Task {
            await cookieBridge.refreshSnapshot()
            var credentials = DownloadCredentials.default
            let variantURL = variant?.playlistURL ?? media.preferredVariant?.playlistURL ?? media.sourceURL
            credentials.cookieHeader = cookieBridge.lastSnapshot.cookieHeader(for: variantURL)
            credentials.referer = media.pageURL?.absoluteString ?? browser.urlString
            downloadManager.enqueue(
                media: media,
                variant: variant,
                audioTrack: audioTrack,
                subtitleTrack: subtitleTrack,
                credentials: credentials,
                outputDirectory: settings.downloadsRoot,
                metadata: metadata ?? .inferred(from: media.displayTitle)
            )
            showDownloads = true
        }
    }

    func redownload(from record: HistoryRecord) {
        pendingVariantMedia = record.asDetectedMedia()
        showHistory = false
    }

    func submitBatch(text: String) {
        let urls = BatchURLParser.parse(text)
        let parts = BatchURLParser.partition(urls)
        Task {
            await cookieBridge.refreshSnapshot()
            var credentials = DownloadCredentials.default
            credentials.referer = browser.urlString
            for url in parts.media {
                let kind: ManifestKind
                switch BatchURLParser.classify(url) {
                case .hls: kind = .hls
                case .dash: kind = .dash
                default: kind = .progressive
                }
                credentials.cookieHeader = cookieBridge.lastSnapshot.cookieHeader(for: url)
                downloadManager.enqueueDirectURL(
                    url,
                    kind: kind,
                    credentials: credentials,
                    outputDirectory: settings.downloadsRoot
                )
            }
            if !parts.media.isEmpty {
                showDownloads = true
            }
            pendingBatchPages = parts.pages
            if let first = pendingBatchPages.first {
                pendingBatchPages.removeFirst()
                awaitingBatchPageLoad = true
                browser.load(url: first)
            }
        }
        showBatchSheet = false
    }

    func openBookmark(_ bookmark: SiteBookmark) {
        do {
            try bookmarks.markVisited(id: bookmark.id)
        } catch {
            AppLog.app.error("Bookmark visit failed: \(error.localizedDescription, privacy: .public)")
        }
        browser.load(url: bookmark.url)
    }

    func toggleCurrentPageBookmark() {
        guard let url = URL(string: browser.urlString),
              url.scheme == "http" || url.scheme == "https"
        else { return }
        do {
            _ = try bookmarks.toggle(title: browser.pageTitle, url: url)
        } catch {
            AppLog.app.error("Bookmark toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isCurrentPageBookmarked: Bool {
        guard let url = URL(string: browser.urlString) else { return false }
        return bookmarks.isBookmarked(url)
    }

    private func handleAutomatedDetection(_ media: DetectedMedia) {
        guard settings.automation.shouldAutoEnqueue(media.kind) else { return }
        let key = media.sourceURL.absoluteString.lowercased()
        guard !autoEnqueuedKeys.contains(key) else { return }
        // Évite d’auto-enqueue un live / playlist encore vide
        if media.kind == .hls, media.segmentCount == 0, media.variants.isEmpty {
            return
        }
        autoEnqueuedKeys.insert(key)
        AppLog.app.info("Auto-enqueue \(media.kindLabel, privacy: .public) \(media.displayTitle, privacy: .public)")
        enqueueSelectedOr(media)
    }

    private func advanceBatchPagesIfNeeded() {
        guard awaitingBatchPageLoad else { return }
        awaitingBatchPageLoad = false
        guard !pendingBatchPages.isEmpty else { return }
        let next = pendingBatchPages.removeFirst()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            awaitingBatchPageLoad = true
            browser.load(url: next)
        }
    }

    private func handleLocalCommand(_ command: LocalCommand) {
        switch command.kind {
        case .ping:
            AppLog.app.info("CLI ping received")
        case .open:
            guard let url = command.url else { return }
            browser.load(url: url)
        case .download:
            guard let url = command.url else { return }
            let classification = MediaDetector.classify(url: url, mimeType: nil)
            switch classification {
            case .hls, .dash, .progressive:
                let kind: ManifestKind = {
                    switch classification {
                    case .hls: return .hls
                    case .dash: return .dash
                    default: return .progressive
                    }
                }()
                Task {
                    await cookieBridge.refreshSnapshot()
                    var credentials = DownloadCredentials.default
                    credentials.cookieHeader = cookieBridge.lastSnapshot.cookieHeader(for: url)
                    credentials.referer = browser.urlString
                    downloadManager.enqueueDirectURL(
                        url,
                        kind: kind,
                        credentials: credentials,
                        outputDirectory: settings.downloadsRoot
                    )
                    showDownloads = true
                }
            case .segment, .unknown:
                browser.load(url: url)
            }
        }
    }
}
