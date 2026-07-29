import AppKit
import Darwin
import Foundation
import Network
import Observation
import SystemConfiguration

enum TunnelProvider: String, Sendable, Equatable, Hashable {
    case tailscale
    case nordvpn
    case stormshield
    case other

    var label: String {
        switch self {
        case .tailscale: return "Tailscale"
        case .nordvpn: return "NordVPN"
        case .stormshield: return "Stormshield"
        case .other: return "VPN"
        }
    }
}

enum VPNIndicatorFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case ignoreTailscale
    case nordVPNOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "Tous les VPN connectés"
        case .ignoreTailscale: return "Ignorer Tailscale (recommandé)"
        case .nordVPNOnly: return "NordVPN uniquement"
        }
    }
}

struct DetectedTunnel: Sendable, Equatable, Hashable {
    var interfaceName: String?
    var serviceName: String
    var provider: TunnelProvider
    var ipv4Addresses: [String]
    var isConnected: Bool
}

struct SystemVPNStatus: Sendable, Equatable {
    var isActive: Bool
    var shortLabel: String
    var detail: String
    var tunnels: [DetectedTunnel]
    var tailscaleConnected: Bool
    var nordVPNConnected: Bool

    static let inactive = SystemVPNStatus(
        isActive: false,
        shortLabel: "VPN inactif",
        detail: "Aucun VPN système connecté",
        tunnels: [],
        tailscaleConnected: false,
        nordVPNConnected: false
    )
}

/// Détection basée surtout sur `scutil --nc list` (état Connected),
/// pas sur la simple présence d’interfaces utun ou d’apps en background.
@MainActor
@Observable
final class SystemVPNMonitor {
    private(set) var status: SystemVPNStatus = .inactive
    var filter: VPNIndicatorFilter = .ignoreTailscale {
        didSet { refresh() }
    }

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "app.openstream.vpn-monitor")
    private var timer: Timer?

    func start() {
        refresh()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        pathMonitor.start(queue: pathQueue)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        pathMonitor.cancel()
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let currentFilter = filter
        Task { [weak self] in
            let tunnels = await Task.detached(priority: .utility) {
                Self.detectTunnels()
            }.value
            guard let self else { return }
            let next = Self.buildStatus(tunnels: tunnels, filter: currentFilter)
            if next != status {
                status = next
                AppLog.session.info(
                    "VPN indicator active=\(next.isActive, privacy: .public) label=\(next.shortLabel, privacy: .public)"
                )
            }
        }
    }

    nonisolated static func buildStatus(
        tunnels: [DetectedTunnel],
        filter: VPNIndicatorFilter
    ) -> SystemVPNStatus {
        let connected = tunnels.filter(\.isConnected)
        let tailscaleConnected = connected.contains { $0.provider == .tailscale }
        let nordVPNConnected = connected.contains { $0.provider == .nordvpn }

        let relevant: [DetectedTunnel] = {
            switch filter {
            case .all:
                return connected
            case .ignoreTailscale:
                return connected.filter { $0.provider != .tailscale }
            case .nordVPNOnly:
                return connected.filter { $0.provider == .nordvpn }
            }
        }()

        let isActive = !relevant.isEmpty

        let shortLabel: String = {
            if !isActive { return "VPN inactif" }
            let providers = Set(relevant.map(\.provider))
            if providers == [.nordvpn] { return "NordVPN actif" }
            if providers == [.tailscale] { return "Tailscale actif" }
            if providers == [.stormshield] { return "Stormshield actif" }
            if providers.count == 1, let only = providers.first {
                return "\(only.label) actif"
            }
            return "VPN actif"
        }()

        var detailParts: [String] = []
        if connected.isEmpty {
            detailParts.append("Aucun service VPN en état Connected (scutil)")
        } else {
            for tunnel in connected {
                var line = "\(tunnel.provider.label) : \(tunnel.serviceName)"
                if let iface = tunnel.interfaceName {
                    line += " (\(iface))"
                }
                if !tunnel.ipv4Addresses.isEmpty {
                    line += " · \(tunnel.ipv4Addresses.joined(separator: ", "))"
                }
                detailParts.append(line)
            }
        }
        if tailscaleConnected && filter == .ignoreTailscale {
            detailParts.append("Tailscale connecté (ignoré pour le voyant)")
        }
        if filter == .nordVPNOnly && !nordVPNConnected {
            detailParts.append(
                "NordVPN non connecté — l’app peut tourner en arrière-plan sans tunnel actif"
            )
        }

        return SystemVPNStatus(
            isActive: isActive,
            shortLabel: shortLabel,
            detail: detailParts.joined(separator: " · "),
            tunnels: tunnels,
            tailscaleConnected: tailscaleConnected,
            nordVPNConnected: nordVPNConnected
        )
    }

    nonisolated static func detectTunnels() -> [DetectedTunnel] {
        var tunnels = parseSCUtilNetworkConnections()
        let ipv4ByInterface = interfaceIPv4Map()

        // Enrichir Tailscale avec l’interface CGNAT si scutil l’a listé
        tunnels = tunnels.map { tunnel in
            var t = tunnel
            if t.provider == .tailscale, t.interfaceName == nil {
                if let match = ipv4ByInterface.first(where: { _, ips in ips.contains(where: isTailscaleCGNAT) }) {
                    t.interfaceName = match.key
                    t.ipv4Addresses = match.value.filter(isTailscaleCGNAT)
                }
            }
            return t
        }

        // Filet de sécurité : Tailscale CGNAT présent mais absent de scutil
        let hasTailscaleService = tunnels.contains { $0.provider == .tailscale && $0.isConnected }
        if !hasTailscaleService {
            for (iface, ips) in ipv4ByInterface {
                let cgnat = ips.filter(isTailscaleCGNAT)
                guard !cgnat.isEmpty else { continue }
                tunnels.append(
                    DetectedTunnel(
                        interfaceName: iface,
                        serviceName: "Tailscale (interface)",
                        provider: .tailscale,
                        ipv4Addresses: cgnat,
                        isConnected: true
                    )
                )
            }
        }

        return tunnels
    }

    /// Parse `scutil --nc list` — source de vérité pour Connected/Disconnected.
    nonisolated static func parseSCUtilNetworkConnections() -> [DetectedTunnel] {
        guard let output = runSCUtilNCList() else { return [] }
        return parseSCUtilOutput(output)
    }

    nonisolated static func parseSCUtilOutput(_ output: String) -> [DetectedTunnel] {
        var result: [DetectedTunnel] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            // Ex: * (Connected)      UUID VPN (io.tailscale...) "Tailscale"   [VPN:...]
            guard line.contains("(Connected)") || line.contains("(Disconnected)") else { continue }
            let connected = line.contains("(Connected)")
            guard connected else { continue } // on ne garde que les connectés pour l’indicateur

            let serviceName = extractQuotedName(from: line) ?? "VPN"
            let provider = classifyService(name: serviceName, line: line)
            result.append(
                DetectedTunnel(
                    interfaceName: nil,
                    serviceName: serviceName,
                    provider: provider,
                    ipv4Addresses: [],
                    isConnected: true
                )
            )
        }
        return result
    }

    nonisolated static func classifyService(name: String, line: String) -> TunnelProvider {
        let haystack = (name + " " + line).lowercased()
        if haystack.contains("tailscale") { return .tailscale }
        if haystack.contains("nordvpn") || haystack.contains("nord vpn") || haystack.contains("nordlynx") {
            return .nordvpn
        }
        if haystack.contains("stormshield") || haystack.contains("storm shield") {
            return .stormshield
        }
        return .other
    }

    nonisolated static func extractQuotedName(from line: String) -> String? {
        guard let first = line.firstIndex(of: "\""),
              let second = line[line.index(after: first)...].firstIndex(of: "\"")
        else { return nil }
        return String(line[line.index(after: first)..<second])
    }

    nonisolated static func runSCUtilNCList() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--nc", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Tailscale CGNAT 100.64.0.0/10
    nonisolated static func isTailscaleCGNAT(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }

    /// Uniquement les utun/ipsec/ppp qui ont une IPv4 non link-local.
    nonisolated static func interfaceIPv4Map() -> [String: [String]] {
        var map: [String: [String]] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [:] }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard looksLikeVPNInterface(name) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            // Ignore link-local
            if ip.hasPrefix("169.254.") { continue }
            map[name, default: []].append(ip)
        }
        return map
    }

    nonisolated static func looksLikeVPNInterface(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("utun") { return true }
        if lower.hasPrefix("ipsec") { return true }
        if lower.hasPrefix("ppp") { return true }
        if lower.hasPrefix("tun") && !lower.hasPrefix("tunnel") { return true }
        if lower.contains("nordlynx") { return true }
        return false
    }
}
