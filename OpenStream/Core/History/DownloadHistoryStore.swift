import Foundation
import Observation

enum HistoryOutcome: String, Codable, Sendable, Hashable {
    case completed
    case failed
}

struct HistoryRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var jobID: UUID?
    var title: String
    var kind: ManifestKind
    var sourceURL: URL
    var variantURL: URL
    var pageURL: URL?
    var exportURL: URL?
    var selectedDashVideoRepresentationID: String?
    var outcome: HistoryOutcome
    var failureMessage: String?
    var createdAt: Date
    var completedAt: Date

    init(
        id: UUID = UUID(),
        jobID: UUID? = nil,
        title: String,
        kind: ManifestKind,
        sourceURL: URL,
        variantURL: URL,
        pageURL: URL? = nil,
        exportURL: URL? = nil,
        selectedDashVideoRepresentationID: String? = nil,
        outcome: HistoryOutcome,
        failureMessage: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date = Date()
    ) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.kind = kind
        self.sourceURL = sourceURL
        self.variantURL = variantURL
        self.pageURL = pageURL
        self.exportURL = exportURL
        self.selectedDashVideoRepresentationID = selectedDashVideoRepresentationID
        self.outcome = outcome
        self.failureMessage = failureMessage
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var kindLabel: String {
        switch kind {
        case .hls: return "HLS"
        case .progressive: return "MP4"
        case .dash: return "DASH"
        }
    }

    var displaySubtitle: String {
        switch outcome {
        case .completed:
            return exportURL?.lastPathComponent ?? "Terminé"
        case .failed:
            return failureMessage ?? "Échec"
        }
    }

    /// Média minimal pour re-télécharger depuis l’historique.
    func asDetectedMedia() -> DetectedMedia {
        let variant = MediaVariant(
            playlistURL: variantURL,
            dashRepresentationID: selectedDashVideoRepresentationID
        )
        return DetectedMedia(
            sourceURL: sourceURL,
            kind: kind,
            suggestedTitle: title,
            pageURL: pageURL,
            variants: [variant],
            preferredVariantID: variant.id,
            isVOD: true
        )
    }
}

/// Historique des exports / échecs (JSON Application Support).
@MainActor
@Observable
final class DownloadHistoryStore {
    private(set) var records: [HistoryRecord] = []

    private let fileURL: URL
    private let maxRecords = 500
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
        fileURL = base.appendingPathComponent("download_history.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    func filtered(query: String) -> [HistoryRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter { record in
            record.title.lowercased().contains(q)
                || record.sourceURL.absoluteString.lowercased().contains(q)
                || record.variantURL.absoluteString.lowercased().contains(q)
                || (record.pageURL?.absoluteString.lowercased().contains(q) ?? false)
                || record.kindLabel.lowercased().contains(q)
        }
    }

    func record(from job: DownloadJob) {
        let outcome: HistoryOutcome
        let failure: String?
        switch job.state {
        case .completed:
            outcome = .completed
            failure = nil
        case .failed(let message):
            outcome = .failed
            failure = message
        default:
            return
        }

        if let index = records.firstIndex(where: { $0.jobID == job.id }) {
            records[index].outcome = outcome
            records[index].failureMessage = failure
            records[index].exportURL = job.exportURL
            records[index].completedAt = Date()
            records[index].title = job.title
            records[index].selectedDashVideoRepresentationID = job.selectedDashVideoRepresentationID
            persist()
            return
        }

        let entry = HistoryRecord(
            jobID: job.id,
            title: job.title,
            kind: job.kind,
            sourceURL: job.sourceURL,
            variantURL: job.variantURL,
            pageURL: job.pageURL,
            exportURL: job.exportURL,
            selectedDashVideoRepresentationID: job.selectedDashVideoRepresentationID,
            outcome: outcome,
            failureMessage: failure,
            createdAt: job.createdAt,
            completedAt: Date()
        )
        records.insert(entry, at: 0)
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        persist()
        AppLog.app.info("History \(outcome.rawValue, privacy: .public) \(job.title, privacy: .public)")
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([HistoryRecord].self, from: data)
        } catch {
            AppLog.app.error("History load failed: \(error.localizedDescription, privacy: .public)")
            records = []
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.app.error("History persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
