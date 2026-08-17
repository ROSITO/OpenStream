import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            DetectedMediaSidebar(
                media: appState.detectedMedia,
                selectedMediaID: $appState.selectedMediaID,
                candidates: appState.candidates,
                selectedCandidateID: $appState.selectedCandidateID,
                showRawCandidates: $appState.showRawCandidates,
                isProcessing: !appState.mediaCatalog.processingURLs.isEmpty,
                onClear: { appState.clearMedia() },
                onDownload: { media in appState.enqueueSelectedOr(media) }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            VStack(spacing: 0) {
                FFmpegSetupBanner()
                BrowserPane()
                if appState.showDownloads {
                    Divider()
                    DownloadsPanel()
                        .frame(minHeight: 140, idealHeight: 180, maxHeight: 240)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    VPNStatusBadge(status: appState.vpnMonitor.status) {
                        appState.vpnMonitor.refresh()
                        appState.showSettings = true
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        appState.showHistory = true
                    } label: {
                        Label("Historique", systemImage: "clock")
                    }
                    .help("Historique des téléchargements")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        appState.showBatchSheet = true
                    } label: {
                        Label("Batch", systemImage: "list.bullet.rectangle")
                    }
                    .help("Enfiler plusieurs URLs")
                }
                ToolbarItem(placement: .automatic) {
                    Toggle(isOn: $appState.showDownloads) {
                        Label("Téléchargements", systemImage: "arrow.down.circle")
                    }
                    .toggleStyle(.button)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        appState.showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "gearshape")
                    }
                    .help("Paramètres")
                }
            }
            .sheet(isPresented: $appState.showSettings) {
                NavigationStack {
                    SettingsView(settings: appState.settings) {
                        appState.applySettings()
                    }
                    .navigationTitle("Paramètres")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Fermer") { appState.showSettings = false }
                        }
                    }
                }
                .frame(width: 520, height: 560)
            }
            .sheet(item: $appState.pendingVariantMedia) { media in
                MediaDownloadSheet(media: media) { variant, audio, subtitle, metadata in
                    appState.startDownload(
                        media: media,
                        variant: variant,
                        audioTrack: audio,
                        subtitleTrack: subtitle,
                        metadata: metadata
                    )
                } onCancel: {
                    appState.pendingVariantMedia = nil
                }
            }
            .sheet(isPresented: $appState.showBookmarkManager) {
                BookmarkManagerSheet()
            }
            .sheet(isPresented: $appState.showHistory) {
                HistorySheet()
            }
            .sheet(isPresented: $appState.showBatchSheet) {
                BatchSheet()
            }
        }
    }
}

struct VPNStatusBadge: View {
    let status: SystemVPNStatus
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isActive ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 8, height: 8)
                Image(systemName: status.isActive ? "lock.shield.fill" : "lock.shield")
                Text(status.shortLabel)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (status.isActive ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .help(status.detail)
        .accessibilityLabel(status.shortLabel)
        .accessibilityValue(status.detail)
    }
}

struct MediaDownloadSheet: View {
    @Environment(AppState.self) private var appState
    let media: DetectedMedia
    let onConfirm: (MediaVariant?, MediaTrack?, MediaTrack?, ExportMetadata) -> Void
    let onCancel: () -> Void

    @State private var selectedVariantID: MediaVariant.ID?
    @State private var selectedAudioID: MediaTrack.ID?
    @State private var selectedSubtitleID: MediaTrack.ID?
    @State private var includeSubtitle = false
    @State private var namingPreset: ExportNamingPreset = .jellyfinMovie
    @State private var exportTitle: String = ""
    @State private var exportYear: String = ""
    @State private var exportShow: String = ""
    @State private var exportSeason: String = "1"
    @State private var exportEpisode: String = "1"
    @FocusState private var titleFocused: Bool

    init(
        media: DetectedMedia,
        onConfirm: @escaping (MediaVariant?, MediaTrack?, MediaTrack?, ExportMetadata) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.media = media
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _selectedVariantID = State(initialValue: media.preferredVariantID ?? media.variants.first?.id)
        let defaultAudio = media.audioTracks.first(where: \.isDefault)
            ?? (media.kind == .dash ? media.audioTracks.first : nil)
            ?? (media.audioTracks.count == 1 ? media.audioTracks.first : nil)
        _selectedAudioID = State(initialValue: defaultAudio?.id)
        _selectedSubtitleID = State(initialValue: media.subtitleTracks.first?.id)
        _includeSubtitle = State(initialValue: false)
        let seed = Self.seedTitle(for: media)
        let parsed = ExportNaming.parseTitleAndYear(from: seed)
        _exportTitle = State(initialValue: parsed.title)
        _exportYear = State(initialValue: parsed.year ?? "")
        _exportShow = State(initialValue: parsed.title)
        _exportSeason = State(initialValue: "1")
        _exportEpisode = State(initialValue: "1")
    }

    /// Titre détecté (souvent le titre de page — à corriger si besoin).
    private static func seedTitle(for media: DetectedMedia) -> String {
        let raw = media.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "video" : raw
    }

    private var trimmedTitle: String {
        exportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var activeTemplate: String {
        namingPreset == .custom ? appState.settings.resolvedNamingTemplate : namingPreset.template
    }

    private var previewPath: String {
        let context = ExportNamingContext(
            title: trimmedTitle.isEmpty ? "video" : trimmedTitle,
            year: exportYear.isEmpty ? nil : exportYear,
            show: exportShow.isEmpty ? trimmedTitle : exportShow,
            season: exportSeason.isEmpty ? nil : exportSeason,
            episode: exportEpisode.isEmpty ? nil : exportEpisode,
            kind: media.kind
        )
        return ExportNaming.relativePath(template: activeTemplate, context: context)
    }

    private var isSeries: Bool {
        namingPreset == .jellyfinSeries
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Télécharger")
                .font(.title2.weight(.semibold))

            Form {
                Section {
                    Picker("Type", selection: $namingPreset) {
                        ForEach(ExportNamingPreset.downloadChoices) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: namingPreset) { _, newValue in
                        if newValue == .jellyfinSeries,
                           exportShow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            exportShow = trimmedTitle
                        }
                    }

                    TextField(
                        isSeries ? "Titre / épisode" : "Ex. Demon Slayer — Le film",
                        text: $exportTitle
                    )
                    .focused($titleFocused)
                    .onSubmit { confirmDownload() }

                    if namingPreset == .jellyfinMovie {
                        TextField("Année (optionnel)", text: $exportYear)
                            .frame(maxWidth: 140)
                    }

                    if isSeries {
                        TextField("Nom de la série", text: $exportShow)
                        HStack {
                            TextField("Saison", text: $exportSeason)
                            TextField("Épisode", text: $exportEpisode)
                        }
                    }

                    Text(previewPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Fichier")
                } footer: {
                    Text(namingPreset.hint)
                        .font(.caption)
                }

                if media.variants.count > 1 {
                    Section("Qualité") {
                        Picker("Variante", selection: $selectedVariantID) {
                            ForEach(media.variants) { variant in
                                Text(variant.displayLabel).tag(Optional(variant.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                if !media.audioTracks.isEmpty {
                    Section("Audio") {
                        Picker("Audio", selection: $selectedAudioID) {
                            if media.kind != .dash {
                                Text("Piste intégrée").tag(Optional<MediaTrack.ID>.none)
                            }
                            ForEach(media.audioTracks) { track in
                                Text(track.displayLabel).tag(Optional(track.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                if !media.subtitleTracks.isEmpty {
                    Section("Sous-titres") {
                        Toggle("Inclure les sous-titres", isOn: $includeSubtitle)
                        if includeSubtitle {
                            Picker("Piste", selection: $selectedSubtitleID) {
                                ForEach(media.subtitleTracks) { track in
                                    Text(track.displayLabel).tag(Optional(track.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Télécharger", action: confirmDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding()
        .frame(width: 500, height: sheetHeight)
        .onAppear {
            let preferred = appState.settings.exportNamingPreset
            if ExportNamingPreset.downloadChoices.contains(preferred) {
                namingPreset = preferred
            } else {
                namingPreset = .jellyfinMovie
            }
            DispatchQueue.main.async {
                titleFocused = true
            }
        }
    }

    private var canConfirm: Bool {
        guard !trimmedTitle.isEmpty else { return false }
        if isSeries {
            let show = exportShow.trimmingCharacters(in: .whitespacesAndNewlines)
            let season = exportSeason.trimmingCharacters(in: .whitespacesAndNewlines)
            let episode = exportEpisode.trimmingCharacters(in: .whitespacesAndNewlines)
            return !show.isEmpty && !season.isEmpty && !episode.isEmpty
        }
        return true
    }

    private func confirmDownload() {
        guard canConfirm else { return }
        let title = trimmedTitle
        let variant = media.variants.first { $0.id == selectedVariantID } ?? media.preferredVariant
        let audio = media.audioTracks.first { $0.id == selectedAudioID }
        let subtitle = includeSubtitle
            ? media.subtitleTracks.first { $0.id == selectedSubtitleID }
            : nil
        let metadata = ExportMetadata(
            title: title,
            year: exportYear.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            show: exportShow.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            season: exportSeason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            episode: exportEpisode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            namingPreset: namingPreset
        )
        onConfirm(variant, audio, subtitle, metadata)
    }

    private var sheetHeight: CGFloat {
        var height: CGFloat = 400
        if isSeries { height += 80 }
        if media.variants.count > 1 { height += 56 }
        if !media.audioTracks.isEmpty { height += 56 }
        if !media.subtitleTracks.isEmpty { height += 90 }
        return min(620, height)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

struct BrowserPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var browser = appState.browser

        VStack(spacing: 0) {
            BrowserToolbar(browser: browser)
            if browser.isLoading {
                ProgressView(value: browser.estimatedProgress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
            WebViewContainer(controller: browser)
                .background(Color(nsColor: .windowBackgroundColor))

            if let error = browser.lastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5))
            }
        }
    }
}

struct BrowserToolbar: View {
    @Environment(AppState.self) private var appState
    @Bindable var browser: BrowserController

    var body: some View {
        HStack(spacing: 8) {
            VPNStatusBadge(status: appState.vpnMonitor.status) {
                appState.vpnMonitor.refresh()
                appState.showSettings = true
            }

            Button(action: browser.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!browser.canGoBack)
            .help("Retour")

            Button(action: browser.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!browser.canGoForward)
            .help("Avancer")

            Button(action: {
                if browser.isLoading { browser.stop() } else { browser.reload() }
            }) {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(browser.isLoading ? "Arrêter" : "Recharger")

            TextField("URL ou recherche", text: $browser.urlString)
                .textFieldStyle(.roundedBorder)
                .onSubmit { browser.loadAddressBarURL() }

            Button {
                appState.toggleCurrentPageBookmark()
            } label: {
                Image(systemName: appState.isCurrentPageBookmarked ? "star.fill" : "star")
            }
            .help(appState.isCurrentPageBookmarked ? "Retirer des favoris" : "Ajouter aux favoris")
            .disabled(!(URL(string: browser.urlString)?.scheme?.hasPrefix("http") == true))

            Menu {
                if appState.bookmarks.bookmarks.isEmpty {
                    Text("Aucun favori")
                } else {
                    ForEach(appState.bookmarks.bookmarks) { bookmark in
                        Button {
                            appState.openBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(bookmark.displayTitle)
                                Text(bookmark.hostLabel)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                Divider()
                Button("Gérer les favoris…") {
                    appState.showBookmarkManager = true
                }
            } label: {
                Image(systemName: "bookmark")
            }
            .help("Favoris")

            Button("Go") { browser.loadAddressBarURL() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(.bar)
    }
}

struct BookmarkManagerSheet: View {
    @Environment(AppState.self) private var appState
    @State private var editingID: SiteBookmark.ID?
    @State private var draftTitle: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if appState.bookmarks.bookmarks.isEmpty {
                    ContentUnavailableView(
                        "Aucun favori",
                        systemImage: "star",
                        description: Text("Ajoutez la page courante avec l’étoile dans la barre d’adresse.")
                    )
                } else {
                    List {
                        ForEach(appState.bookmarks.bookmarks) { bookmark in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if editingID == bookmark.id {
                                        TextField("Titre", text: $draftTitle)
                                            .onSubmit { commitRename(bookmark) }
                                    } else {
                                        Text(bookmark.displayTitle)
                                            .font(.body.weight(.medium))
                                    }
                                    Text(bookmark.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Button {
                                    appState.openBookmark(bookmark)
                                    appState.showBookmarkManager = false
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .help("Ouvrir")
                            }
                            .contextMenu {
                                Button("Ouvrir") {
                                    appState.openBookmark(bookmark)
                                    appState.showBookmarkManager = false
                                }
                                Button("Renommer") {
                                    editingID = bookmark.id
                                    draftTitle = bookmark.title
                                }
                                Button("Supprimer", role: .destructive) {
                                    try? appState.bookmarks.remove(id: bookmark.id)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            let ids = indexSet.compactMap { appState.bookmarks.bookmarks[safe: $0]?.id }
                            for id in ids {
                                try? appState.bookmarks.remove(id: id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favoris")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { appState.showBookmarkManager = false }
                }
                if editingID != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") {
                            if let id = editingID,
                               let bookmark = appState.bookmarks.bookmarks.first(where: { $0.id == id })
                            {
                                commitRename(bookmark)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 420)
    }

    private func commitRename(_ bookmark: SiteBookmark) {
        try? appState.bookmarks.rename(id: bookmark.id, title: draftTitle)
        editingID = nil
        draftTitle = ""
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct DetectedMediaSidebar: View {
    let media: [DetectedMedia]
    @Binding var selectedMediaID: DetectedMedia.ID?
    let candidates: [NetworkMediaCandidate]
    @Binding var selectedCandidateID: NetworkMediaCandidate.ID?
    @Binding var showRawCandidates: Bool
    let isProcessing: Bool
    let onClear: () -> Void
    let onDownload: (DetectedMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Médias détectés")
                    .font(.headline)
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text("\(media.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Effacer", action: onClear)
                    .disabled(media.isEmpty && candidates.isEmpty)
            }
            .padding(12)

            Divider()

            if media.isEmpty {
                ContentUnavailableView(
                    "Aucun média classifié",
                    systemImage: "film.stack",
                    description: Text("Les playlists HLS (.m3u8) et fichiers MP4 deviennent des médias ici. Les segments .ts restent dans les candidats bruts.")
                )
            } else {
                List(media, selection: $selectedMediaID) { item in
                    DetectedMediaRow(media: item, onDownload: { onDownload(item) })
                        .tag(item.id)
                }
                .listStyle(.sidebar)
            }

            DisclosureGroup(isExpanded: $showRawCandidates) {
                if candidates.isEmpty {
                    Text("Aucun candidat brut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(candidates) { candidate in
                        CandidateRow(candidate: candidate)
                            .padding(.vertical, 2)
                    }
                }
            } label: {
                Text("Candidats bruts (\(candidates.count))")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct DetectedMediaRow: View {
    let media: DetectedMedia
    var onDownload: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(media.kindLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(kindColor.opacity(0.2), in: Capsule())
                    .foregroundStyle(kindColor)

                if media.kind == .hls || media.kind == .dash, media.variants.count > 1 {
                    Text("\(media.variants.count) variantes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !media.audioTracks.isEmpty {
                    Text("\(media.audioTracks.count) audio")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !media.subtitleTracks.isEmpty {
                    Text("\(media.subtitleTracks.count) subs")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let isVOD = media.isVOD {
                    Text(isVOD ? "VOD" : "Live?")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onDownload {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Télécharger")
                }
            }

            Text(media.displayTitle)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            if let preferred = media.preferredVariant {
                Text(preferred.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let segmentCount = media.segmentCount, media.kind == .hls || media.kind == .dash {
                HStack(spacing: 6) {
                    Text("\(segmentCount) segments")
                    if let duration = media.formattedDuration {
                        Text("·")
                        Text(duration)
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            } else if let duration = media.formattedDuration {
                Text(duration)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if let length = media.contentLength {
                Text(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(media.sourceURL.host() ?? media.sourceURL.absoluteString)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let onDownload {
                Button("Télécharger", action: onDownload)
            }
            Button("Copier l’URL source") {
                copy(media.sourceURL.absoluteString)
            }
            if let preferred = media.preferredVariant {
                Button("Copier l’URL variante préférée") {
                    copy(preferred.playlistURL.absoluteString)
                }
            }
        }
    }

    private var kindColor: Color {
        switch media.kind {
        case .hls: return .blue
        case .progressive: return .green
        case .dash: return .orange
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct DownloadsPanel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Téléchargements")
                    .font(.headline)
                Spacer()
                Text("\(appState.downloadManager.jobs.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let error = appState.downloadManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            if appState.downloadManager.jobs.isEmpty {
                Text("Aucun téléchargement. Cliquez ↓ sur un média détecté.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer(minLength: 0)
            } else {
                List(appState.downloadManager.jobs) { job in
                    DownloadJobRow(job: job)
                }
                .listStyle(.plain)
            }
        }
        .background(.bar)
    }
}

struct DownloadJobRow: View {
    @Environment(AppState.self) private var appState
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(job.kind == .hls ? "HLS" : (job.kind == .dash ? "DASH" : "MP4"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: job.state.progressValue)
                .progressViewStyle(.linear)

            HStack {
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                actionButtons
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch job.state {
        case .queued, .preparing, .downloading, .assembling:
            Button("Annuler") { appState.downloadManager.cancel(job.id) }
                .font(.caption)
                .disabled({
                    if case .assembling = job.state { return true }
                    return false
                }())
        case .cancelled, .failed:
            Button("Reprendre") { appState.downloadManager.resume(job.id) }
                .font(.caption)
            Button("Assembler") { appState.downloadManager.assembleExisting(job) }
                .font(.caption)
            Button("Supprimer") { appState.downloadManager.remove(job.id) }
                .font(.caption)
        case .completed:
            Button("MP4") { appState.downloadManager.reveal(job) }
                .font(.caption)
            Button("Supprimer") { appState.downloadManager.remove(job.id) }
                .font(.caption)
        }
    }
}

struct CandidateRow: View {
    let candidate: NetworkMediaCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(candidate.pathExtensionHint.isEmpty ? "media" : candidate.pathExtensionHint.uppercased())
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text(candidate.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(candidate.url.absoluteString)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            Text(candidate.displayHost)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copier l’URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(candidate.url.absoluteString, forType: .string)
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
