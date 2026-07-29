import Foundation
import Testing
@testable import OpenStream

struct SystemVPNMonitorTests {
    @Test func detectsTailscaleCGNAT() {
        #expect(SystemVPNMonitor.isTailscaleCGNAT("100.100.50.1"))
        #expect(SystemVPNMonitor.isTailscaleCGNAT("100.64.0.1"))
        #expect(!SystemVPNMonitor.isTailscaleCGNAT("100.63.0.1"))
        #expect(!SystemVPNMonitor.isTailscaleCGNAT("10.0.0.1"))
    }

    @Test func parsesSCUtilTailscaleConnected() {
        let sample = """
        Available network connection services in the current set (*=enabled):
        * (Disconnected)   A5D4EA66-B63B-4FB5-9824-5E5413955241 PPP --> Arduino Micro "Arduino Micro" [PPP:Modem]
        * (Connected)      5F4FFCFD-E11D-470C-AA63-8797AFE60692 VPN (io.tailscale.ipn.macsys) "Tailscale" [VPN:io.tailscale.ipn.macsys]
        """
        let tunnels = SystemVPNMonitor.parseSCUtilOutput(sample)
        #expect(tunnels.count == 1)
        #expect(tunnels[0].provider == .tailscale)
        #expect(tunnels[0].isConnected)
        #expect(tunnels[0].serviceName == "Tailscale")
    }

    @Test func parsesSCUtilNordVPNConnected() {
        let sample = """
        * (Connected)      11111111-1111-1111-1111-111111111111 VPN (com.nordvpn.macos) "NordVPN" [VPN:com.nordvpn.macos]
        """
        let tunnels = SystemVPNMonitor.parseSCUtilOutput(sample)
        #expect(tunnels.count == 1)
        #expect(tunnels[0].provider == .nordvpn)
    }

    @Test func ignoresDisconnectedServices() {
        let sample = """
        * (Disconnected)   11111111-1111-1111-1111-111111111111 VPN (com.nordvpn.macos) "NordVPN" [VPN:com.nordvpn.macos]
        """
        let tunnels = SystemVPNMonitor.parseSCUtilOutput(sample)
        #expect(tunnels.isEmpty)
    }

    @Test func ignoreTailscaleFilter() {
        let tunnels = [
            DetectedTunnel(
                interfaceName: "utun9",
                serviceName: "Tailscale",
                provider: .tailscale,
                ipv4Addresses: ["100.64.1.2"],
                isConnected: true
            )
        ]
        let status = SystemVPNMonitor.buildStatus(tunnels: tunnels, filter: .ignoreTailscale)
        #expect(status.isActive == false)
        #expect(status.tailscaleConnected == true)
        #expect(status.shortLabel == "VPN inactif")
        #expect(status.detail.contains("ignoré"))
    }

    @Test func nordFilterStaysInactiveWithoutNord() {
        let tunnels = [
            DetectedTunnel(
                interfaceName: "utun9",
                serviceName: "Tailscale",
                provider: .tailscale,
                ipv4Addresses: ["100.64.1.2"],
                isConnected: true
            )
        ]
        let status = SystemVPNMonitor.buildStatus(tunnels: tunnels, filter: .nordVPNOnly)
        #expect(status.isActive == false)
        #expect(status.nordVPNConnected == false)
    }
}
