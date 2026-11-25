import CoreWLAN
import Foundation

/// Scans for nearby Wi-Fi networks and joins one. CoreWLAN calls block for
/// seconds, so everything runs on a private queue and completes on main.
final class WiFiNetworkService {
    enum ScanResult {
        case networks([PanelModel.WiFiNetwork])
        /// Networks were found, but Location Services redacted every name.
        case needsLocation
        case failed
    }

    enum JoinResult { case joined, needsPassword, failed }

    private let queue = DispatchQueue(label: "duoicon.wifi-networks")
    /// Latest scan, keyed by SSID. Only touched on `queue`.
    private var found: [String: CWNetwork] = [:]

    func scan(completion: @escaping (ScanResult) -> Void) {
        queue.async { [weak self] in
            let result = self?.performScan() ?? .failed
            DispatchQueue.main.async { completion(result) }
        }
    }

    func join(_ network: PanelModel.WiFiNetwork, password: String?, completion: @escaping (JoinResult) -> Void) {
        queue.async { [weak self] in
            let result = self?.performJoin(network, password: password) ?? .failed
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func performScan() -> ScanResult {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn(),
              let scanned = try? interface.scanForNetworks(withName: nil) else { return .failed }
        let current = interface.ssid()
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        let known = Set(profiles.compactMap(\.ssid))

        // One entry per name: the strongest access point wins.
        var best: [String: CWNetwork] = [:]
        for network in scanned {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            if let other = best[ssid], other.rssiValue >= network.rssiValue { continue }
            best[ssid] = network
        }
        found = best
        if best.isEmpty && !scanned.isEmpty { return .needsLocation }

        let list = best.map { ssid, network in
            PanelModel.WiFiNetwork(ssid: ssid, bars: WiFiReader.bars(rssi: network.rssiValue),
                                   isSecure: !network.supportsSecurity(.none),
                                   isKnown: known.contains(ssid), isCurrent: ssid == current)
        }
        return .networks(list.sorted(by: Self.order))
    }

    private func performJoin(_ target: PanelModel.WiFiNetwork, password: String?) -> JoinResult {
        guard let interface = CWWiFiClient.shared().interface(),
              let network = found[target.ssid] else { return .failed }
        // A saved network may join from the keychain; a new secured one needs a password first.
        if target.isSecure && password == nil && !target.isKnown { return .needsPassword }
        do {
            try interface.associate(to: network, password: password)
            return .joined
        } catch {
            // Fall through: a saved network may still join with its stored credentials.
        }
        // CoreWLAN does not read saved passwords from the keychain, but
        // networksetup joins a preferred network with its stored credentials.
        if password == nil && target.isKnown, let device = interface.interfaceName,
           joinWithNetworksetup(ssid: target.ssid, device: device, interface: interface) {
            return .joined
        }
        return target.isSecure ? .needsPassword : .failed
    }

    private func joinWithNetworksetup(ssid: String, device: String, interface: CWInterface) -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-setairportnetwork", device, ssid]
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return false }
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // networksetup can exit 0 on failure, so trust only the interface itself.
        for _ in 0..<20 {
            if interface.ssid() == ssid { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Current network first, then saved ones, then by signal and name.
    static func order(_ a: PanelModel.WiFiNetwork, _ b: PanelModel.WiFiNetwork) -> Bool {
        if a.isCurrent != b.isCurrent { return a.isCurrent }
        if a.isKnown != b.isKnown { return a.isKnown }
        if a.bars != b.bars { return a.bars > b.bars }
        return a.ssid.localizedCaseInsensitiveCompare(b.ssid) == .orderedAscending
    }
}

/// Low Power Mode. Reading is public API; changing it needs `pmset` as root,
/// so macOS asks for an administrator password each time.
enum LowPowerMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    static func set(_ enabled: Bool, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(enabled ? 1 : 0)\" with administrator privileges"]
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
