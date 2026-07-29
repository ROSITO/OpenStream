import Foundation
import CoreGraphics

enum HLSPlaylistKind: Sendable, Hashable {
    case master
    case media
}

struct HLSStreamInf: Sendable, Hashable {
    var bandwidth: Int?
    var averageBandwidth: Int?
    var resolution: CGSize?
    var codecs: String?
    var uri: URL
}

struct HLSSegment: Sendable, Hashable {
    var duration: Double
    var uri: URL
    var byteRange: String?
}

struct HLSMediaPlaylist: Sendable, Hashable {
    var targetDuration: Double?
    var mediaSequence: Int?
    var hasEndList: Bool
    var mapURI: URL?
    var segments: [HLSSegment]
    var totalDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }
}

struct HLSPlaylist: Sendable, Hashable {
    var kind: HLSPlaylistKind
    var baseURL: URL
    var streams: [HLSStreamInf]
    var media: HLSMediaPlaylist?
    var renditions: [HLSMediaRendition]
}

struct HLSMediaRendition: Sendable, Hashable {
    enum Kind: String, Sendable { case audio, subtitles, closedCaptions, video }
    var kind: Kind
    var groupID: String
    var name: String?
    var language: String?
    var uri: URL?
    var isDefault: Bool
    var isAutoSelect: Bool
}

enum HLSParserError: Error, LocalizedError, Sendable {
    case emptyDocument
    case missingHeader
    case invalidURI(String)

    var errorDescription: String? {
        switch self {
        case .emptyDocument: return "Playlist HLS vide"
        case .missingHeader: return "En-tête #EXTM3U manquant"
        case .invalidURI(let s): return "URI HLS invalide: \(s)"
        }
    }
}

enum HLSParser {
    static func parse(text: String, playlistURL: URL) throws -> HLSPlaylist {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#EXT-X-COMMENT") }

        guard let first = lines.first else { throw HLSParserError.emptyDocument }
        guard first == "#EXTM3U" || first.hasPrefix("#EXTM3U") else {
            throw HLSParserError.missingHeader
        }

        let isMaster = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF") }
        if isMaster {
            return try parseMaster(lines: lines, playlistURL: playlistURL)
        }
        return try parseMedia(lines: lines, playlistURL: playlistURL)
    }

    private static func parseMaster(lines: [String], playlistURL: URL) throws -> HLSPlaylist {
        var streams: [HLSStreamInf] = []
        var renditions: [HLSMediaRendition] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                let type = (attrs["TYPE"] ?? "").uppercased()
                let kind: HLSMediaRendition.Kind? = {
                    switch type {
                    case "AUDIO": return .audio
                    case "SUBTITLES": return .subtitles
                    case "CLOSED-CAPTIONS": return .closedCaptions
                    case "VIDEO": return .video
                    default: return nil
                    }
                }()
                if let kind {
                    let uri = attrs["URI"].flatMap { try? resolveURI($0, relativeTo: playlistURL) }
                    renditions.append(
                        HLSMediaRendition(
                            kind: kind,
                            groupID: attrs["GROUP-ID"] ?? "",
                            name: attrs["NAME"],
                            language: attrs["LANGUAGE"],
                            uri: uri,
                            isDefault: (attrs["DEFAULT"] ?? "").uppercased() == "YES",
                            isAutoSelect: (attrs["AUTOSELECT"] ?? "").uppercased() == "YES"
                        )
                    )
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                index += 1
                guard index < lines.count else { break }
                let uriLine = lines[index]
                if uriLine.hasPrefix("#") { continue }
                let uri = try resolveURI(uriLine, relativeTo: playlistURL)
                let resolution = parseResolution(attrs["RESOLUTION"])
                streams.append(
                    HLSStreamInf(
                        bandwidth: Int(attrs["BANDWIDTH"] ?? ""),
                        averageBandwidth: Int(attrs["AVERAGE-BANDWIDTH"] ?? ""),
                        resolution: resolution,
                        codecs: attrs["CODECS"],
                        uri: uri
                    )
                )
            }
            index += 1
        }
        return HLSPlaylist(kind: .master, baseURL: playlistURL, streams: streams, media: nil, renditions: renditions)
    }

    private static func parseMedia(lines: [String], playlistURL: URL) throws -> HLSPlaylist {
        var targetDuration: Double?
        var mediaSequence: Int?
        var hasEndList = false
        var mapURI: URL?
        var segments: [HLSSegment] = []
        var pendingDuration: Double?
        var pendingByteRange: String?

        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(String(line.dropFirst("#EXT-X-TARGETDURATION:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(String(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)))
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"] {
                    mapURI = try resolveURI(unquote(uri), relativeTo: playlistURL)
                }
            } else if line.hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst("#EXTINF:".count))
                let durationPart = payload.split(separator: ",", maxSplits: 1).first.map(String.init) ?? payload
                pendingDuration = Double(durationPart)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingByteRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#") {
                continue
            } else if let duration = pendingDuration {
                let uri = try resolveURI(line, relativeTo: playlistURL)
                segments.append(
                    HLSSegment(duration: duration, uri: uri, byteRange: pendingByteRange)
                )
                pendingDuration = nil
                pendingByteRange = nil
            }
        }

        let media = HLSMediaPlaylist(
            targetDuration: targetDuration,
            mediaSequence: mediaSequence,
            hasEndList: hasEndList,
            mapURI: mapURI,
            segments: segments
        )
        return HLSPlaylist(kind: .media, baseURL: playlistURL, streams: [], media: media, renditions: [])
    }

    static func resolveURI(_ raw: String, relativeTo base: URL) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
            return resolved
        }
        throw HLSParserError.invalidURI(trimmed)
    }

    static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentKey = ""
        var currentValue = ""
        var state = AttributeParseState.key
        var isQuoted = false

        func commit() {
            let key = currentKey.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty else { return }
            result[key] = unquote(currentValue.trimmingCharacters(in: .whitespaces))
            currentKey = ""
            currentValue = ""
        }

        for ch in raw {
            switch state {
            case .key:
                if ch == "=" {
                    state = .value
                    isQuoted = false
                } else {
                    currentKey.append(ch)
                }
            case .value:
                if currentValue.isEmpty, ch == "\"" {
                    isQuoted = true
                    currentValue.append(ch)
                } else if isQuoted {
                    currentValue.append(ch)
                    if ch == "\"" {
                        isQuoted = false
                    }
                } else if ch == "," {
                    commit()
                    state = .key
                } else {
                    currentValue.append(ch)
                }
            }
        }
        commit()
        return result
    }

    private enum AttributeParseState { case key, value }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func parseResolution(_ raw: String?) -> CGSize? {
        guard let raw else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1])
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
