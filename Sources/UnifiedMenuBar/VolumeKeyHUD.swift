import AppKit
import ApplicationServices

final class VolumeKeyMonitor {
    var handle: ((Int, Bool) -> Bool)?
    var onActiveChange: ((Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumed = Set<Int>()
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            onActiveChange?(false)
            return
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: 1 << 14,
                               callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.consumed.removeAll()
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard let key = NSEvent(cgEvent: event), key.type == .systemDefined,
                  key.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
            let code = (key.data1 >> 16) & 0xffff
            let state = (key.data1 >> 8) & 0xff
            guard [0, 1, 7].contains(code) else { return Unmanaged.passUnretained(event) }
            if state == 0x0b {
                return monitor.consumed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
            }
            guard state == 0x0a else { return Unmanaged.passUnretained(event) }
            if code == 7 && (key.data1 & 1) != 0 {
                return monitor.consumed.contains(code) ? nil : Unmanaged.passUnretained(event)
            }
            // Preserve Option-volume's system shortcut; Option-Shift uses fine steps.
            if key.modifierFlags.contains(.option) && !key.modifierFlags.contains(.shift) {
                return Unmanaged.passUnretained(event)
            }
            let fine = key.modifierFlags.contains([.option, .shift])
            if monitor.handle?(code, fine) == true {
                monitor.consumed.insert(code)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            onActiveChange?(false)
            return
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onActiveChange?(true)
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        start()
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

final class VolumeKeyHUD {
    var onVolume: ((Float32) -> Void)?
    var onMute: (() -> Void)?
    private let panel: NSPanel
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "0%")
    private let mute = NSButton()
    private var dismissal: Timer?
    private var deadline: TimeInterval = 0
    private var visibilityTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background
        mute.frame = NSRect(x: 12, y: 14, width: 28, height: 28)
        mute.isBordered = false
        mute.toolTip = "Mute / Unmute"
        mute.target = self
        mute.action = #selector(toggleMute)
        slider.frame = NSRect(x: 48, y: 16, width: 158, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Output volume")
        slider.target = self
        slider.action = #selector(changeVolume)
        label.frame = NSRect(x: 212, y: 20, width: 56, height: 17)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        for view in [mute, slider, label] { background.addSubview(view) }
    }

    func update(volume: Float32, muted: Bool, canSetVolume: Bool, canSetMute: Bool) {
        slider.doubleValue = Double(volume)
        slider.isEnabled = canSetVolume
        mute.isEnabled = canSetMute
        label.stringValue = muted ? "Muted" : "\(Int(volume * 100))%"
        mute.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            accessibilityDescription: "Mute")
    }

    static func frame(below anchor: NSRect, screen: NSRect) -> NSRect {
        NSRect(x: max(screen.minX + 8, min(anchor.midX - 140, screen.maxX - 288)),
               y: anchor.minY - 64, width: 280, height: 56)
    }

    func show(below button: NSStatusBarButton) {
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(Self.frame(below: anchor, screen: screen.frame), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        animateVisibility(to: 1)
        deadline = ProcessInfo.processInfo.systemUptime + 2.5
        guard dismissal == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let hovering = self.panel.frame.contains(NSEvent.mouseLocation)
            if hovering || NSEvent.pressedMouseButtons != 0 {
                self.deadline = ProcessInfo.processInfo.systemUptime + 2.5
            }
            if ProcessInfo.processInfo.systemUptime >= self.deadline { self.hide() }
        }
        dismissal = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        dismissal?.invalidate()
        dismissal = nil
        animateVisibility(to: 0)
    }

    private func animateVisibility(to target: CGFloat) {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        let initial = panel.alphaValue
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(initial - target) > 0.001 else {
            panel.alphaValue = target
            if target == 0 { panel.orderOut(nil) }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = target == 1 ? 0.18 : 0.14
        // Resume from current opacity when another volume key interrupts dismissal.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            self.panel.alphaValue = initial + (target - initial) * eased
            if progress >= 1 {
                timer.invalidate()
                self.visibilityTimer = nil
                if target == 0 { self.panel.orderOut(nil) }
            }
        }
        visibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func writePreview(to url: URL) throws {
        guard let view = panel.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func changeVolume() {
        onVolume?(Float32(slider.doubleValue))
        deadline = ProcessInfo.processInfo.systemUptime + 2.5
    }

    @objc private func toggleMute() {
        onMute?()
        deadline = ProcessInfo.processInfo.systemUptime + 2.5
    }
}
