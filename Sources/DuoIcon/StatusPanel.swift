import AppKit
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app,
/// so Esc, Tab, ⌘R and ⌘Q work while the frontmost app stays frontmost.
final class StatusPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || onKeyEquivalent(event)
    }
}

/// The app stays in the background, so the panel's window is never active.
/// Without this, the first click (for example on the island) would be swallowed.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel window: where it sits, when it shows, and when it goes away.
/// The window is kept only as tall as the surface needs; it grows before the
/// surface grows and shrinks after the surface settles, so its transparent
/// margins never linger over other apps.
final class StatusPanelController: NSObject, NSWindowDelegate {
    let model: PanelModel
    private let panel: StatusPanel
    private let host: FirstClickHostingView<SurfaceView>
    private weak var anchor: NSStatusBarButton?
    private var surfaceHeight: CGFloat = 0
    private var lastPanelHeight: CGFloat?
    private var windowHeight: CGFloat = 0
    private var shrink: DispatchWorkItem?
    private var orderOut: DispatchWorkItem?
    private var islandTimer: Timer?
    private var islandDeadline: TimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDismissal: TimeInterval = 0

    private static let settleDelay = 0.6
    private static let islandLifetime: TimeInterval = 2.5

    init(model: PanelModel) {
        self.model = model
        panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: SurfaceView.windowWidth, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        host = FirstClickHostingView(rootView: SurfaceView(model: model))
        super.init()
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.onKeyEquivalent = { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
            switch event.charactersIgnoringModifiers {
            case "q": self?.model.onQuit(); return true
            case "w": self?.close(); return true
            default: return false
            }
        }
        // The controller sizes the window; SwiftUI must not add size constraints to it.
        host.sizingOptions = []
        host.rootView = SurfaceView(model: model) { [weak self] height in self?.surfaceDidResize(height) }
        panel.contentView = host
    }

    var isPanelOpen: Bool { model.mode == .panel }

    // MARK: Geometry

    /// Window frame whose surface is centered under `anchor`, kept 8 pt inside the screen.
    static func frame(height: CGFloat, below anchor: NSRect, screen: NSRect) -> NSRect {
        let margin = SurfaceView.margin
        let surfaceMinX = max(screen.minX + 8,
                              min(anchor.midX - SurfaceView.panelWidth / 2, screen.maxX - 8 - SurfaceView.panelWidth))
        return NSRect(x: surfaceMinX - margin.leading, y: anchor.minY - height,
                      width: SurfaceView.windowWidth, height: height)
    }

    static func windowHeight(forSurface height: CGFloat) -> CGFloat {
        SurfaceView.margin.top + height + SurfaceView.margin.bottom
    }

    private func setWindowHeight(_ height: CGFloat) {
        windowHeight = height
        guard let button = anchor, let window = button.window, let screen = window.screen else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(Self.frame(height: height, below: rect, screen: screen.frame), display: true)
    }

    private func surfaceDidResize(_ height: CGFloat) {
        guard height > 0 else { return }
        surfaceHeight = height
        if model.shape == .panel && model.mode == .panel { lastPanelHeight = height }
        let needed = Self.windowHeight(forSurface: height)
        shrink?.cancel()
        if needed > windowHeight {
            setWindowHeight(needed)
        } else if needed < windowHeight {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.setWindowHeight(Self.windowHeight(forSurface: self.surfaceHeight))
            }
            shrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
        }
    }

    /// Room for the panel before SwiftUI has measured it: the last known height,
    /// or everything between the menu bar and the bottom of the screen.
    private func provisionalPanelHeight(for button: NSStatusBarButton) -> CGFloat {
        if let lastPanelHeight { return Self.windowHeight(forSurface: lastPanelHeight) }
        guard let window = button.window, let screen = window.screen else { return 640 }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return max(200, rect.minY - screen.visibleFrame.minY)
    }

    private var surfaceRectOnScreen: NSRect {
        let size = model.shape == .island
            ? SurfaceView.islandSize
            : CGSize(width: SurfaceView.panelWidth, height: surfaceHeight)
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - SurfaceView.margin.top - size.height,
                      width: size.width, height: size.height)
    }

    // MARK: Showing and hiding

    func toggle(below button: NSStatusBarButton) {
        if model.mode == .panel {
            close()
        } else if ProcessInfo.processInfo.systemUptime - lastDismissal > 0.3 {
            // A click on the icon that just dismissed the panel must not reopen it.
            open(.panel, below: button)
        }
    }

    /// Shows the compact volume island, unless the full panel is already open.
    func showIsland(below button: NSStatusBarButton) {
        guard model.mode != .panel else { return }
        open(.island, below: button)
    }

    func expandIsland() {
        guard model.mode == .island, let anchor else { return }
        open(.panel, below: anchor)
    }

    private func open(_ mode: PanelModel.Mode, below button: NSStatusBarButton) {
        anchor = button
        orderOut?.cancel()
        let height = mode == .island
            ? Self.windowHeight(forSurface: SurfaceView.islandSize.height)
            : provisionalPanelHeight(for: button)
        let appearing = model.mode == .closed
        if appearing {
            // Start from the target shape so a fresh open scales in rather than morphing.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.prepareShape(mode) }
            windowHeight = 0
        }
        setWindowHeight(max(height, appearing ? 0 : windowHeight))
        if !panel.isVisible { panel.orderFrontRegardless() }
        if appearing {
            DispatchQueue.main.async { [weak self] in self?.model.setMode(mode) }
        } else {
            model.setMode(mode)
        }

        if mode == .panel {
            stopIslandTimer()
            panel.makeKey()
            installMonitors()
            DispatchQueue.main.async { button.highlight(true) }
        } else {
            armIsland()
        }
    }

    func close() {
        guard model.mode != .closed else { return }
        lastDismissal = ProcessInfo.processInfo.systemUptime
        model.setMode(.closed)
        removeMonitors()
        stopIslandTimer()
        anchor?.highlight(false)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.mode == .closed else { return }
            self.panel.orderOut(nil)
        }
        orderOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Island lifetime

    private func armIsland() {
        islandDeadline = ProcessInfo.processInfo.systemUptime + Self.islandLifetime
        guard islandTimer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.model.mode == .island else { self.stopIslandTimer(); return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.surfaceRectOnScreen.contains(NSEvent.mouseLocation) || NSEvent.pressedMouseButtons != 0 {
                self.islandDeadline = now + Self.islandLifetime
            }
            if now >= self.islandDeadline { self.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        islandTimer = timer
    }

    private func stopIslandTimer() {
        islandTimer?.invalidate()
        islandTimer = nil
    }

    // MARK: Dismissal

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        // Clicks in other apps, including other menu bar items.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel {
                // A click in the transparent margin around the surface counts as outside.
                let point = self.panel.convertPoint(toScreen: event.locationInWindow)
                if !self.surfaceRectOnScreen.contains(point) { self.close() }
            } else if event.window !== self.anchor?.window {
                self.close()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        if model.mode == .panel { close() }
    }
}
