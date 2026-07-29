import Foundation
import os

enum AppLog {
    static let subsystem = "app.openstream"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let hls = Logger(subsystem: subsystem, category: "hls")
    static let download = Logger(subsystem: subsystem, category: "download")
    static let ffmpeg = Logger(subsystem: subsystem, category: "ffmpeg")
}
