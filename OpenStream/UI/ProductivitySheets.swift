import SwiftUI
import AppKit

struct HistorySheet: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""

    private var filtered: [HistoryRecord] {
        appState.history.filtered(query: query)
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.history.records.isEmpty {
                    ContentUnavailableView(
                        "Aucun historique",
                        systemImage: "clock",
                        description: Text("Les téléchargements terminés ou en échec apparaîtront ici.")
                    )
                } else {
                    VStack(spacing: 0) {
                        if let error = appState.downloadManager.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        } else if let info = appState.downloadManager.lastInfo {
                            Text(info)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        List {
                            ForEach(filtered) { record in
                                HistoryRow(record: record)
                            }
                            .onDelete { indexSet in
                                let snapshot = filtered
                                for index in indexSet {
                                    guard snapshot.indices.contains(index) else { continue }
                                    appState.history.remove(id: snapshot[index].id)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Rechercher titre ou URL")
            .navigationTitle("Historique")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { appState.showHistory = false }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Vider") {
                        appState.history.clear()
                    }
                    .disabled(appState.history.records.isEmpty)
                }
            }
        }
        .frame(width: 560, height: 480)
    }
}

private struct HistoryRow: View {
    @Environment(AppState.self) private var appState
    let record: HistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.kindLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text(record.outcome == .completed ? "OK" : "Échec")
                        .font(.caption2)
                        .foregroundStyle(record.outcome == .completed ? .green : .red)
                }
                Text(record.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(record.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.sourceURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(spacing: 6) {
                Button("Re-télécharger") {
                    appState.redownload(from: record)
                }
                .buttonStyle(.bordered)
                if let export = record.exportURL, FileManager.default.fileExists(atPath: export.path) {
                    Button("Révéler") {
                        NSWorkspace.shared.activateFileViewerSelecting([export])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button("Sync…") {
                        appState.avSyncTarget = AVSyncTarget(url: export, title: record.title)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(appState.downloadManager.isRepairingSync)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Re-télécharger") { appState.redownload(from: record) }
            if let export = record.exportURL, FileManager.default.fileExists(atPath: export.path) {
                Button("Ajuster sync…") {
                    appState.avSyncTarget = AVSyncTarget(url: export, title: record.title)
                }
                .disabled(appState.downloadManager.isRepairingSync)
            }
            Button("Copier l’URL source") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.sourceURL.absoluteString, forType: .string)
            }
            Button("Supprimer", role: .destructive) {
                appState.history.remove(id: record.id)
            }
        }
    }
}

struct BatchSheet: View {
    @Environment(AppState.self) private var appState
    @State private var text = ""

    private var preview: (media: Int, pages: Int) {
        let urls = BatchURLParser.parse(text)
        let parts = BatchURLParser.partition(urls)
        return (parts.media.count, parts.pages.count)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Collez plusieurs URLs (une par ligne). Les médias (m3u8 / mpd / mp4) partent en téléchargement ; les pages s’ouvrent à la suite dans le navigateur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary)
                    )

                Text("\(preview.media) média(s) · \(preview.pages) page(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Annuler") { appState.showBatchSheet = false }
                    Button("Lancer") {
                        appState.submitBatch(text: text)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(BatchURLParser.parse(text).isEmpty)
                }
            }
            .padding()
            .navigationTitle("Batch URLs")
        }
        .frame(width: 520, height: 360)
    }
}
