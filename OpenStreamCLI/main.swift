import Foundation

enum LocalCommandKind: String, Codable {
    case download
    case open
    case ping
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

enum LocalCommandPaths {
    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenStream", isDirectory: true)
    }

    static var inbox: URL {
        supportRoot.appendingPathComponent("inbox", isDirectory: true)
    }
}

func printUsage() {
    print(
        """
        openstream-cli — file d’attente locale OpenStream

        Usage:
          openstream-cli download <url>   Enfile un téléchargement média (m3u8/mpd/mp4)
          openstream-cli open <url>       Demande d’ouvrir une page dans le navigateur
          openstream-cli ping             Test de l’inbox
          openstream-cli inbox            Affiche le chemin de l’inbox
          openstream-cli help

        Les commandes sont écrites dans:
          ~/Library/Application Support/OpenStream/inbox/
        """
    )
}

func enqueue(_ kind: LocalCommandKind, url: URL?) {
    let root = LocalCommandPaths.supportRoot
    let inbox = LocalCommandPaths.inbox
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

    let command = LocalCommand(kind: kind, url: url)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    do {
        let data = try encoder.encode(command)
        let name = String(format: "%lld-%@.json", Int64(Date().timeIntervalSince1970 * 1000), command.id.uuidString)
        let file = inbox.appendingPathComponent(name)
        try data.write(to: file, options: [.atomic])
        print("OK \(kind.rawValue) → \(file.path)")
        print("Support: \(root.path)")
        print("Astuce: laissez OpenStream ouvert pour traiter la commande.")
    } catch {
        fputs("Erreur: \(error.localizedDescription)\n", stderr)
        exit(3)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    printUsage()
    exit(1)
}

switch command {
case "help", "-h", "--help":
    printUsage()
case "download":
    guard args.count >= 2, let url = URL(string: args[1]), url.host != nil else {
        fputs("Usage: openstream-cli download <url>\n", stderr)
        exit(2)
    }
    enqueue(.download, url: url)
case "open":
    guard args.count >= 2, let url = URL(string: args[1]), url.host != nil else {
        fputs("Usage: openstream-cli open <url>\n", stderr)
        exit(2)
    }
    enqueue(.open, url: url)
case "ping":
    enqueue(.ping, url: nil)
    print("ping queued — OpenStream doit être lancé pour traiter l’inbox.")
case "inbox":
    print(LocalCommandPaths.inbox.path)
default:
    fputs("Commande inconnue: \(command)\n", stderr)
    printUsage()
    exit(1)
}
