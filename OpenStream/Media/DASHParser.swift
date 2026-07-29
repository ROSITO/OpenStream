import Foundation
import CoreGraphics

enum DASHParserError: Error, LocalizedError, Sendable {
    case emptyDocument
    case invalidXML
    case noVideoRepresentation
    case message(String)

    var errorDescription: String? {
        switch self {
        case .emptyDocument: return "Manifest DASH vide"
        case .invalidXML: return "MPD XML invalide"
        case .noVideoRepresentation: return "Aucune Representation vidéo dans le MPD"
        case .message(let text): return text
        }
    }
}

struct DASHSegmentRef: Sendable, Hashable {
    var url: URL
    var isInitialization: Bool
}

struct DASHRepresentation: Sendable, Hashable, Identifiable {
    var id: String
    var bandwidth: Int?
    var width: Int?
    var height: Int?
    var codecs: String?
    var mimeType: String?
    var segments: [DASHSegmentRef]
    var language: String?
    var label: String?
}

struct DASHManifest: Sendable, Hashable {
    var baseURL: URL
    var videoRepresentations: [DASHRepresentation]
    var audioRepresentations: [DASHRepresentation]
    var textRepresentations: [DASHRepresentation]
    var periodDurationSeconds: Double?
}

enum DASHParser {
    static func parse(xml: String, manifestURL: URL) throws -> DASHManifest {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DASHParserError.emptyDocument }
        guard let data = trimmed.data(using: .utf8) else { throw DASHParserError.invalidXML }

        let document = try XMLDocument(data: data, options: [.documentTidyXML])
        guard let root = document.rootElement() else { throw DASHParserError.invalidXML }

        let periodDuration = parseDuration(root.attribute(forName: "mediaPresentationDuration")?.stringValue)
            ?? parseDuration(firstChild(root, local: "Period")?.attribute(forName: "duration")?.stringValue)

        var video: [DASHRepresentation] = []
        var audio: [DASHRepresentation] = []
        var text: [DASHRepresentation] = []

        let periods = children(root, local: "Period")
        let periodNodes = periods.isEmpty ? [root] : periods

        for period in periodNodes {
            let periodBase = resolveBaseURL(from: period, fallback: manifestURL)
            for adaptation in children(period, local: "AdaptationSet") {
                let contentType = (
                    adaptation.attribute(forName: "contentType")?.stringValue
                        ?? adaptation.attribute(forName: "mimeType")?.stringValue
                        ?? ""
                ).lowercased()
                let lang = adaptation.attribute(forName: "lang")?.stringValue
                let label = adaptation.attribute(forName: "label")?.stringValue
                    ?? firstChild(adaptation, local: "Label")?.stringValue

                for representation in children(adaptation, local: "Representation") {
                    let rep = try parseRepresentation(
                        representation,
                        adaptation: adaptation,
                        baseURL: resolveBaseURL(from: representation, fallback: periodBase),
                        periodDuration: periodDuration,
                        language: lang,
                        label: label
                    )
                    let mime = (rep.mimeType ?? contentType).lowercased()
                    if mime.contains("video") || (rep.width != nil && rep.height != nil) {
                        video.append(rep)
                    } else if mime.contains("audio") {
                        audio.append(rep)
                    } else if mime.contains("text") || mime.contains("ttml") || mime.contains("vtt") || contentType.contains("text") {
                        text.append(rep)
                    } else if contentType.contains("video") {
                        video.append(rep)
                    } else if contentType.contains("audio") {
                        audio.append(rep)
                    } else {
                        // Heuristique : bandwidth élevé + codecs avc → vidéo
                        if (rep.codecs ?? "").contains("avc") || (rep.codecs ?? "").contains("hvc") {
                            video.append(rep)
                        } else if (rep.codecs ?? "").contains("mp4a") {
                            audio.append(rep)
                        }
                    }
                }
            }
        }

        guard !video.isEmpty else { throw DASHParserError.noVideoRepresentation }
        return DASHManifest(
            baseURL: manifestURL,
            videoRepresentations: video,
            audioRepresentations: audio,
            textRepresentations: text,
            periodDurationSeconds: periodDuration
        )
    }

    static func units(
        for representation: DASHRepresentation,
        directoryPrefix: String = "",
        indexOffset: Int = 0
    ) throws -> [DownloadUnit] {
        guard !representation.segments.isEmpty else { throw DownloadError.emptyPlaylist }
        var units: [DownloadUnit] = []
        for (index, segment) in representation.segments.enumerated() {
            let fallback = segment.isInitialization ? ".mp4" : ".m4s"
            let ext = segment.url.pathExtension.isEmpty ? fallback : ".\(segment.url.pathExtension)"
            let kind = segment.isInitialization ? "init" : "seg"
            let name = String(format: "%05d_%@%@", index, kind, ext)
            units.append(
                DownloadUnit(
                    index: indexOffset + index,
                    url: segment.url,
                    fileName: directoryPrefix + name
                )
            )
        }
        return units
    }

    // MARK: - Private

    private static func parseRepresentation(
        _ representation: XMLElement,
        adaptation: XMLElement,
        baseURL: URL,
        periodDuration: Double?,
        language: String?,
        label: String?
    ) throws -> DASHRepresentation {
        let id = representation.attribute(forName: "id")?.stringValue
            ?? UUID().uuidString
        let bandwidth = Int(representation.attribute(forName: "bandwidth")?.stringValue ?? "")
        let width = Int(representation.attribute(forName: "width")?.stringValue
            ?? adaptation.attribute(forName: "width")?.stringValue ?? "")
        let height = Int(representation.attribute(forName: "height")?.stringValue
            ?? adaptation.attribute(forName: "height")?.stringValue ?? "")
        let codecs = representation.attribute(forName: "codecs")?.stringValue
            ?? adaptation.attribute(forName: "codecs")?.stringValue
        let mimeType = representation.attribute(forName: "mimeType")?.stringValue
            ?? adaptation.attribute(forName: "mimeType")?.stringValue

        let segments = try resolveSegments(
            representation: representation,
            adaptation: adaptation,
            baseURL: baseURL,
            periodDuration: periodDuration
        )

        return DASHRepresentation(
            id: id,
            bandwidth: bandwidth,
            width: width,
            height: height,
            codecs: codecs,
            mimeType: mimeType,
            segments: segments,
            language: language,
            label: label
        )
    }

    private static func resolveSegments(
        representation: XMLElement,
        adaptation: XMLElement,
        baseURL: URL,
        periodDuration: Double?
    ) throws -> [DASHSegmentRef] {
        // SegmentList (rep or adaptation)
        if let list = firstChild(representation, local: "SegmentList")
            ?? firstChild(adaptation, local: "SegmentList")
        {
            return try parseSegmentList(list, baseURL: baseURL)
        }

        // SegmentTemplate
        if let template = firstChild(representation, local: "SegmentTemplate")
            ?? firstChild(adaptation, local: "SegmentTemplate")
        {
            return try parseSegmentTemplate(template, baseURL: baseURL, periodDuration: periodDuration, representationID: representation.attribute(forName: "id")?.stringValue ?? "1", bandwidth: representation.attribute(forName: "bandwidth")?.stringValue ?? "0")
        }

        // BaseURL only (single file)
        if let base = firstChild(representation, local: "BaseURL")?.stringValue
            ?? firstChild(adaptation, local: "BaseURL")?.stringValue
        {
            let url = try resolveURI(base, relativeTo: baseURL)
            return [DASHSegmentRef(url: url, isInitialization: false)]
        }

        throw DASHParserError.message("Representation sans SegmentList/Template/BaseURL")
    }

    private static func parseSegmentList(_ list: XMLElement, baseURL: URL) throws -> [DASHSegmentRef] {
        var segments: [DASHSegmentRef] = []
        if let initEl = firstChild(list, local: "Initialization") {
            let source = initEl.attribute(forName: "sourceURL")?.stringValue
                ?? initEl.attribute(forName: "sourceUrl")?.stringValue
            if let source {
                segments.append(DASHSegmentRef(url: try resolveURI(source, relativeTo: baseURL), isInitialization: true))
            }
        }
        for urlEl in children(list, local: "SegmentURL") {
            if let media = urlEl.attribute(forName: "media")?.stringValue {
                segments.append(DASHSegmentRef(url: try resolveURI(media, relativeTo: baseURL), isInitialization: false))
            }
        }
        guard !segments.isEmpty else { throw DASHParserError.message("SegmentList vide") }
        return segments
    }

    private static func parseSegmentTemplate(
        _ template: XMLElement,
        baseURL: URL,
        periodDuration: Double?,
        representationID: String,
        bandwidth: String
    ) throws -> [DASHSegmentRef] {
        var segments: [DASHSegmentRef] = []
        let timescale = Double(template.attribute(forName: "timescale")?.stringValue ?? "1") ?? 1
        let startNumber = Int(template.attribute(forName: "startNumber")?.stringValue ?? "1") ?? 1
        let durationAttr = Double(template.attribute(forName: "duration")?.stringValue ?? "") 

        if let initTemplate = template.attribute(forName: "initialization")?.stringValue {
            let path = expandTemplate(initTemplate, number: startNumber, representationID: representationID, bandwidth: bandwidth, time: 0)
            segments.append(DASHSegmentRef(url: try resolveURI(path, relativeTo: baseURL), isInitialization: true))
        }

        let mediaTemplate = template.attribute(forName: "media")?.stringValue
        guard let mediaTemplate else {
            guard !segments.isEmpty else { throw DASHParserError.message("SegmentTemplate incomplet") }
            return segments
        }

        // SegmentTimeline if present
        if let timeline = firstChild(template, local: "SegmentTimeline") {
            var number = startNumber
            var time: Int64 = 0
            for s in children(timeline, local: "S") {
                let d = Int64(s.attribute(forName: "d")?.stringValue ?? "0") ?? 0
                let r = Int(s.attribute(forName: "r")?.stringValue ?? "0") ?? 0
                if let t = Int64(s.attribute(forName: "t")?.stringValue ?? "") {
                    time = t
                }
                let repeatCount = max(0, r) + 1
                for _ in 0..<repeatCount {
                    let path = expandTemplate(mediaTemplate, number: number, representationID: representationID, bandwidth: bandwidth, time: time)
                    segments.append(DASHSegmentRef(url: try resolveURI(path, relativeTo: baseURL), isInitialization: false))
                    number += 1
                    time += d
                }
            }
        } else if let durationAttr, durationAttr > 0, let periodDuration, periodDuration > 0, timescale > 0 {
            let segmentDurationSeconds = durationAttr / timescale
            let count = max(1, Int(ceil(periodDuration / segmentDurationSeconds)))
            for i in 0..<count {
                let number = startNumber + i
                let path = expandTemplate(mediaTemplate, number: number, representationID: representationID, bandwidth: bandwidth, time: Int64(Double(i) * durationAttr))
                segments.append(DASHSegmentRef(url: try resolveURI(path, relativeTo: baseURL), isInitialization: false))
            }
        } else {
            // Au moins un segment template
            let path = expandTemplate(mediaTemplate, number: startNumber, representationID: representationID, bandwidth: bandwidth, time: 0)
            segments.append(DASHSegmentRef(url: try resolveURI(path, relativeTo: baseURL), isInitialization: false))
        }

        guard segments.contains(where: { !$0.isInitialization }) || segments.count >= 1 else {
            throw DASHParserError.message("Aucun segment DASH résolu")
        }
        return segments
    }

    private static func expandTemplate(_ template: String, number: Int, representationID: String, bandwidth: String, time: Int64) -> String {
        // Échapper `$$` (dollar littéral) avant les tokens `$…$`.
        let placeholder = "\u{FFF0}"
        var result = template.replacingOccurrences(of: "$$", with: placeholder)
        result = result.replacingOccurrences(of: "$RepresentationID$", with: representationID)
        result = result.replacingOccurrences(of: "$Bandwidth$", with: bandwidth)
        result = result.replacingOccurrences(of: "$Number%05d$", with: String(format: "%05d", number))
        result = result.replacingOccurrences(of: "$Number$", with: "\(number)")
        result = result.replacingOccurrences(of: "$Time$", with: "\(time)")
        return result.replacingOccurrences(of: placeholder, with: "$")
    }

    private static func resolveBaseURL(from element: XMLElement, fallback: URL) -> URL {
        if let value = firstChild(element, local: "BaseURL")?.stringValue,
           let url = try? resolveURI(value, relativeTo: fallback)
        {
            return url
        }
        return fallback
    }

    private static func resolveURI(_ raw: String, relativeTo base: URL) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved
        }
        throw DASHParserError.message("URI DASH invalide: \(trimmed)")
    }

    private static func parseDuration(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        // ISO 8601 duration PT1H2M3.5S
        guard raw.hasPrefix("PT") || raw.hasPrefix("P") else {
            return Double(raw)
        }
        var s = raw
        if s.hasPrefix("P"), !s.hasPrefix("PT") {
            // PnDTnhnmns — on gère un sous-ensemble PT...
            if let tIndex = s.firstIndex(of: "T") {
                s = "PT" + s[s.index(after: tIndex)...]
            } else {
                return nil
            }
        }
        s = String(s.dropFirst(2)) // drop PT
        var total: Double = 0
        var number = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else {
                let value = Double(number) ?? 0
                number = ""
                switch ch {
                case "H": total += value * 3600
                case "M": total += value * 60
                case "S": total += value
                default: break
                }
            }
        }
        return total > 0 ? total : nil
    }

    private static func children(_ element: XMLElement, local: String) -> [XMLElement] {
        (element.children ?? []).compactMap { node in
            guard let el = node as? XMLElement else { return nil }
            let name = el.localName ?? el.name ?? ""
            return name == local || name.hasSuffix(":" + local) ? el : nil
        }
    }

    private static func firstChild(_ element: XMLElement, local: String) -> XMLElement? {
        children(element, local: local).first
    }
}
