import SwiftUI

/// Display state for the status panel. AppController pushes readings in; the
/// SwiftUI views call back out through the action closures.
final class PanelModel: ObservableObject {
    enum Mode: Equatable { case closed, island, panel }
    enum Section: Equatable { case volume, wifi, battery }
    enum AccessRequest: Equatable { case idle, waiting, granted }

    struct Snapshot: Equatable {
        var volume: Float = 0
        var isMuted = false
        var canSetVolume = true
        var canSetMute = true
        var batteryPercent = -1
        var isCharging = false
        var isPluggedIn = false
        var batterySummary = ""
        var powerSource = ""
        var wifiConnected = false
        var wifiTitle = ""
        var wifiBars = 0
        var wifiNeedsLocation = false
        var volumeHUDActive = false
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var mode: Mode = .closed
    /// The last visible mode, so a closing surface keeps its shape while it fades.
    @Published private(set) var shape: Mode = .panel
    @Published var expanded: Section?
    @Published var accessPromptDismissed = false
    @Published var accessRequest: AccessRequest = .idle

    /// While the user drags the slider, timer readings must not move the thumb.
    var isDraggingVolume = false

    var onVolume: (Float) -> Void = { _ in }
    var onToggleMute: () -> Void = {}
    var onOpenSettings: (Section) -> Void = { _ in }
    var onRequestAccess: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}
    var onExpandIsland: () -> Void = {}

    var showsAccessPrompt: Bool {
        (!snapshot.volumeHUDActive || accessRequest == .granted) && !accessPromptDismissed
    }

    func apply(_ next: Snapshot) {
        var next = next
        if isDraggingVolume {
            next.volume = snapshot.volume
            next.isMuted = snapshot.isMuted
        }
        if accessRequest == .waiting && next.volumeHUDActive {
            accessRequest = .granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.accessRequest = .idle
            }
        }
        guard next != snapshot else { return }
        snapshot = next
    }

    /// Optimistic local update so the slider and labels follow the pointer at once.
    func setLocalVolume(_ value: Float) {
        snapshot.volume = value
        if value > 0 { snapshot.isMuted = false }
    }

    func setMode(_ next: Mode) {
        guard next != mode else { return }
        // A request the user declined in System Settings must not stay stuck on "Waiting".
        if next == .panel && mode == .closed && accessRequest == .waiting { accessRequest = .idle }
        mode = next
        if next != .closed { shape = next }
    }

    /// Sets the shape without a mode change, for a surface about to appear.
    func prepareShape(_ next: Mode) {
        if next != .closed { shape = next }
    }

    func toggle(_ section: Section) {
        expanded = expanded == section ? nil : section
    }
}
