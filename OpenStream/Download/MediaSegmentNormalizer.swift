import Foundation

/// Certains CDN (TikTok / proxies) préfixent un faux PNG/JPEG devant du MPEG-TS
/// pour tromper les filtres — `file` voit une image 1×1, le reste est de la vidéo.
enum MediaSegmentNormalizer {
    enum PayloadKind: String, Sendable {
        case mpegts
        case fmp4
        case unknown
    }

    struct Result: Sendable {
        let data: Data
        let kind: PayloadKind
        let strippedBytes: Int
    }

    /// Retire un éventuel leurre image ; détecte TS / fMP4.
    static func normalize(_ data: Data) -> Result {
        guard !data.isEmpty else {
            return Result(data: data, kind: .unknown, strippedBytes: 0)
        }

        if let stripped = stripImageDecoy(from: data) {
            let kind = detectKind(stripped)
            return Result(data: stripped, kind: kind, strippedBytes: data.count - stripped.count)
        }

        return Result(data: data, kind: detectKind(data), strippedBytes: 0)
    }

    /// Extension fichier canonique pour le mux FFmpeg / playlists locales.
    static func preferredExtension(for kind: PayloadKind, currentExtension: String) -> String {
        let current = currentExtension.lowercased()
        switch kind {
        case .mpegts:
            return "ts"
        case .fmp4:
            if current == "mp4" || current == "m4s" || current == "m4a" || current == "cmfv" || current == "cmfa" {
                return current
            }
            return "m4s"
        case .unknown:
            return current.isEmpty ? "bin" : current
        }
    }

    static func detectKind(_ data: Data) -> PayloadKind {
        if looksLikeMPEGTS(data) { return .mpegts }
        if looksLikeFMP4(data) { return .fmp4 }
        return .unknown
    }

    // MARK: - Decoy strip

    private static func stripImageDecoy(from data: Data) -> Data? {
        // PNG
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            if let iend = data.range(of: Data([0x49, 0x45, 0x4E, 0x44])) {
                let after = iend.upperBound + 4 // CRC
                guard after < data.count else { return nil }
                let payload = data.subdata(in: after..<data.count)
                if detectKind(payload) != .unknown { return payload }
            }
        }

        // JPEG SOI
        if data.count > 4, data[0] == 0xFF, data[1] == 0xD8 {
            if let offset = firstMPEGTSOffset(in: data, searchLimit: min(data.count, 64 * 1024)),
               offset > 0
            {
                let payload = data.subdata(in: offset..<data.count)
                if detectKind(payload) != .unknown { return payload }
            }
            if let offset = firstFMP4Offset(in: data, searchLimit: min(data.count, 64 * 1024)),
               offset > 0
            {
                let payload = data.subdata(in: offset..<data.count)
                if detectKind(payload) != .unknown { return payload }
            }
        }

        // GIF
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) {
            if let offset = firstMPEGTSOffset(in: data, searchLimit: min(data.count, 64 * 1024)),
               offset > 0
            {
                let payload = data.subdata(in: offset..<data.count)
                if detectKind(payload) != .unknown { return payload }
            }
        }

        return nil
    }

    private static func looksLikeMPEGTS(_ data: Data) -> Bool {
        firstMPEGTSOffset(in: data, searchLimit: min(data.count, 188 * 4)) == 0
            || (data.count > 188 && data[0] == 0x47 && data[188] == 0x47)
    }

    private static func looksLikeFMP4(_ data: Data) -> Bool {
        firstFMP4Offset(in: data, searchLimit: min(data.count, 64)) == 0
    }

    private static func firstMPEGTSOffset(in data: Data, searchLimit: Int) -> Int? {
        let limit = min(data.count, searchLimit)
        guard limit > 188 * 2 else { return nil }
        var i = 0
        while i + 188 * 2 < limit {
            if data[i] == 0x47, data[i + 188] == 0x47, data[i + 376] == 0x47 {
                return i
            }
            i += 1
        }
        // two syncs only
        i = 0
        while i + 188 < limit {
            if data[i] == 0x47, data[i + 188] == 0x47 {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func firstFMP4Offset(in data: Data, searchLimit: Int) -> Int? {
        let limit = min(data.count, searchLimit)
        guard limit > 8 else { return nil }
        // box type at +4
        let needles = [Data("ftyp".utf8), Data("moof".utf8), Data("styp".utf8)]
        for needle in needles {
            if let r = data.range(of: needle, in: 0..<limit), r.lowerBound >= 4 {
                return r.lowerBound - 4
            }
        }
        return nil
    }
}
