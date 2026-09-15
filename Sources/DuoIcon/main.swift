import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN
import IOKit.ps

private final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 36)
    private let volume = VolumeController()
    private let battery = BatteryReader()
    private let wifi = WiFiReader()
    private let volumeKeys = VolumeKeyMonitor()
    private let volumeHUD = VolumeKeyHUD()

    private var refreshTimer: Timer?
    private var centerNotice = CenterNotice()
    private var transition = CenterTransition()
    private var animationTimer: Timer?
    private var renderIcon: (() -> Void)?
    private weak var volumeSlider: NSSlider?
    private weak var volumeLabel: NSTextField?
    private weak var muteButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        volumeKeys.handle = { [weak self] code, fine in
            guard let self, let button = self.statusItem.button, button.window?.isVisible == true else { return false }
            guard code == 7 ? self.volume.canSetMute : self.volume.canSetVolume else { return false }
            if code == 7 {
                let desired = !self.volume.isMuted
                self.volume.isMuted = desired
                guard self.volume.isMuted == desired else { return false }
            } else {
                let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
                let desired = max(0, min(1, self.volume.outputVolume + (code == 0 ? step : -step)))
                self.volume.outputVolume = desired
                guard abs(self.volume.outputVolume - desired) < 0.005 else { return false }
                if self.volume.isMuted { self.volume.isMuted = false }
            }
            self.centerNotice.showVolume(now: ProcessInfo.processInfo.systemUptime)
            // Return from the event tap before querying Wi-Fi or drawing the HUD.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateStatusIcon()
                self.volumeHUD.show(below: button)
            }
            return true
        }
        volumeHUD.onVolume = { [weak self] value in
            guard let self else { return }
            self.volume.outputVolume = value
            if value > 0 && self.volume.isMuted { self.volume.isMuted = false }
            self.updateStatusIcon()
        }
        volumeHUD.onMute = { [weak self] in self?.toggleMute() }
        volumeKeys.start()
        configureStatusItem()
        refreshMenu()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatusIcon()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        if !volumeKeys.isActive {
            volumeKeys.requestAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        animationTimer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem.button?.toolTip = "Wi-Fi, Volume, Battery"
        statusItem.button?.imagePosition = .imageOnly
        updateStatusIcon()
    }

    @objc private func refreshMenu() {
        updateStatusIcon()
        statusItem.menu = buildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        volumeHUD.hide()
        menu.removeAllItems()
        for item in buildMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func updateStatusIcon() {
        volumeKeys.start()
        let batteryStatus = battery.status()
        let wifiStatus = wifi.status()
        let outputVolume = volume.outputVolume
        let isMuted = volume.isMuted
        let center = centerNotice.update(volume: outputVolume, isMuted: isMuted,
                                         battery: batteryStatus, now: ProcessInfo.processInfo.systemUptime)
        if let button = statusItem.button {
            button.appearsDisabled = false
            button.contentTintColor = nil
        }
        transition.set(center, now: ProcessInfo.processInfo.systemUptime,
                       reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        renderIcon = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.image = StatusIcon.make(
            battery: batteryStatus,
            wifi: wifiStatus,
            volume: outputVolume,
            isMuted: isMuted,
            appearance: self.statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance,
            center: center,
            layers: self.transition.layers(at: ProcessInfo.processInfo.systemUptime)
        )
        }
        renderIcon?()
        if transition.isAnimating(at: ProcessInfo.processInfo.systemUptime), animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.renderIcon?()
                if !self.transition.isAnimating(at: ProcessInfo.processInfo.systemUptime) {
                    timer.invalidate()
                    self.animationTimer = nil
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
        volumeSlider?.doubleValue = Double(outputVolume)
        volumeSlider?.isEnabled = volume.canSetVolume
        muteButton?.isEnabled = volume.canSetMute
        volumeLabel?.stringValue = isMuted ? "Muted" : "\(Int(outputVolume * 100))%"
        muteButton?.image = NSImage(systemSymbolName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Mute")
        volumeHUD.update(volume: outputVolume, muted: isMuted,
                         canSetVolume: volume.canSetVolume, canSetMute: volume.canSetMute)
        let summary = "\(batteryStatus.summary), \(wifiStatus.title), Volume \(isMuted ? 0 : Int(outputVolume * 100))%"
        statusItem.button?.toolTip = summary
        statusItem.button?.setAccessibilityLabel(summary)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        addVolumeSection(to: menu)
        if !volumeKeys.isActive {
            let access = NSMenuItem(title: "Enable Icon-Anchored Volume HUD...", action: #selector(enableVolumeKeyHUD), keyEquivalent: "")
            access.target = self
            menu.addItem(access)
            menu.addItem(disabledItem("Accessibility permission required"))
        }
        menu.addItem(.separator())
        addWiFiSection(to: menu)
        menu.addItem(.separator())
        addBatterySection(to: menu)
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshMenu), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit DuoIcon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    private func addWiFiSection(to menu: NSMenu) {
        let status = wifi.status()
        menu.addItem(disabledItem("Wi-Fi"))
        menu.addItem(disabledItem(status.title))

        let settings = NSMenuItem(title: "Open Wi-Fi Settings", action: #selector(openWiFiSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func addVolumeSection(to menu: NSMenu) {
        menu.addItem(disabledItem("Volume"))

        let row = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 38))
        let mute = NSButton(image: NSImage(systemSymbolName: volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: "Mute")!, target: self, action: #selector(toggleMute))
        mute.frame = NSRect(x: 12, y: 5, width: 28, height: 28)
        mute.isBordered = false
        mute.toolTip = "Mute / Unmute"
        row.addSubview(mute)
        muteButton = mute
        let slider = NSSlider(value: Double(volume.outputVolume), minValue: 0, maxValue: 1,
                              target: self, action: #selector(changeVolume(_:)))
        slider.frame = NSRect(x: 48, y: 7, width: 158, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Output volume")
        slider.isEnabled = volume.canSetVolume
        mute.isEnabled = volume.canSetMute
        row.addSubview(slider)
        volumeSlider = slider
        let label = NSTextField(labelWithString: volume.isMuted ? "Muted" : "\(Int(volume.outputVolume * 100))%")
        label.frame = NSRect(x: 212, y: 11, width: 56, height: 17)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.alignment = .right
        row.addSubview(label)
        volumeLabel = label
        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)

        let settings = NSMenuItem(title: "Open Sound Settings", action: #selector(openSoundSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func addBatterySection(to menu: NSMenu) {
        let status = battery.status()
        menu.addItem(disabledItem("Battery"))
        menu.addItem(disabledItem(status.summary))
        menu.addItem(disabledItem(status.powerSource))

        let settings = NSMenuItem(title: "Open Battery Settings", action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func changeVolume(_ sender: NSSlider) {
        volume.outputVolume = Float32(sender.doubleValue)
        if sender.doubleValue > 0 && volume.isMuted { volume.isMuted = false }
        updateStatusIcon()
    }

    @objc private func enableVolumeKeyHUD() {
        volumeKeys.requestAccess()
    }

    @objc private func toggleMute() {
        volume.isMuted = !volume.isMuted
        updateStatusIcon()
    }

    @objc private func openWiFiSettings() {
        openSettings("x-apple.systempreferences:com.apple.Wi-Fi-Settings.extension")
    }

    @objc private func openSoundSettings() {
        openSettings("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    @objc private func openBatterySettings() {
        openSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension")
    }

    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct CenterTransition {
    private var target: CenterNotice.Kind?
    private var source: [(CenterNotice.Kind, CGFloat)] = []
    private var started: TimeInterval = 0
    private var duration: TimeInterval = 0

    mutating func set(_ kind: CenterNotice.Kind, now: TimeInterval, reducedMotion: Bool) {
        guard kind != target else { return }
        source = layers(at: now)
        duration = target == nil || reducedMotion ? 0 : 0.18
        target = kind
        started = now
    }

    func isAnimating(at now: TimeInterval) -> Bool { now < started + duration }

    func layers(at now: TimeInterval) -> [(CenterNotice.Kind, CGFloat)] {
        guard let target else { return [] }
        guard isAnimating(at: now) else { return [(target, 1)] }
        let progress = max(0, min(1, (now - started) / duration))
        // Fade out fully before revealing the next symbol so slashes cannot overlap Wi-Fi.
        if progress < 0.5 {
            let opacity = CGFloat(pow(1 - progress * 2, 2))
            return source.map { ($0.0, $0.1 * opacity) }
        }
        let opacity = CGFloat(1 - pow(1 - (progress - 0.5) * 2, 2))
        return [(target, opacity)]
    }
}

private struct CenterNotice {
    enum Kind { case wifi, volume, battery }

    private var previousVolume: Float32?
    private var previousMute: Bool?
    private var wasLow = false
    private var volumeUntil: TimeInterval = 0
    private var batteryUntil: TimeInterval = 0
    private var pendingBattery = false

    mutating func showVolume(now: TimeInterval) {
        volumeUntil = now + 2
    }

    mutating func update(volume: Float32, isMuted: Bool, battery: BatteryReader.Status,
                         now: TimeInterval) -> Kind {
        if let previousVolume, let previousMute,
           abs(volume - previousVolume) > 0.001 || previousMute != isMuted {
            volumeUntil = now + 2
        }
        previousVolume = volume
        previousMute = isMuted

        let low = (0...10).contains(battery.percentage) && !battery.isCharging
        if low && !wasLow { pendingBattery = true }
        wasLow = low
        if !low {
            pendingBattery = false
            batteryUntil = 0
        }
        // Let a low-battery notice wait until the user's volume interaction ends.
        if now < volumeUntil { return .volume }
        if pendingBattery {
            batteryUntil = now + 3
            pendingBattery = false
        }
        return now < batteryUntil ? .battery : .wifi
    }
}

private enum StatusIcon {
    static func make(
        battery: BatteryReader.Status,
        wifi: WiFiReader.Status,
        volume: Float32,
        isMuted: Bool,
        appearance: NSAppearance,
        center: CenterNotice.Kind = .wifi,
        layers: [(CenterNotice.Kind, CGFloat)]? = nil
    ) -> NSImage {
        let size = NSSize(width: 28, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let tone: MenuBarTone = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawBatteryArc(context: context, status: battery, tone: tone)
        for (kind, opacity) in layers ?? [(center, 1)] {
        let symbolName: String
        switch kind {
        case .wifi:
            symbolName = wifi.isConnected ? "wifi" : "wifi.slash"
        case .volume:
            symbolName = isMuted || volume <= 0 ? "speaker.slash.fill" :
                volume <= 0.33 ? "speaker.wave.1.fill" :
                volume <= 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .battery:
            symbolName = "battery.0percent"
        }
        context.saveGState()
        context.setAlpha(opacity)
        drawSystemSymbol(symbolName, color: kind == .battery ? .systemRed : primaryColor(for: tone),
                         in: NSRect(x: 7.8, y: 8.2, width: 12.4, height: 9))
        context.restoreGState()
        }
        drawVolumeDots(context: context, volume: volume, isMuted: isMuted, tone: tone)

        image.unlockFocus()
        image.isTemplate = !battery.isCharging && !battery.isPluggedIn && battery.percentage > 10
        return image
    }

    private static func drawBatteryArc(context: CGContext, status: BatteryReader.Status, tone: MenuBarTone) {
        defer {
            if status.isPluggedIn {
                let endpoint = CGPoint(x: 14 + 10.2 * cos(-CGFloat.pi / 6), y: 12 - 10.2 / 2)
                context.setFillColor(primaryColor(for: tone).cgColor)
                context.fillEllipse(in: CGRect(x: endpoint.x - 1.9, y: endpoint.y - 1.9, width: 3.8, height: 3.8))
                context.setFillColor(NSColor.systemGreen.cgColor)
                context.fillEllipse(in: CGRect(x: endpoint.x - 1.4, y: endpoint.y - 1.4, width: 2.8, height: 2.8))
            }
        }
        let center = NSPoint(x: 14, y: 12)
        let radius: CGFloat = 10.2
        let lineWidth: CGFloat = 1.9
        let percent = CGFloat(max(0, min(status.percentage, 100))) / 100

        context.setLineWidth(lineWidth)
        context.setStrokeColor(inactiveColor(for: tone).cgColor)

        let startAngle: CGFloat = 210
        let endAngle: CGFloat = -30
        let sweep = startAngle - endAngle

        let background = NSBezierPath()
        background.lineCapStyle = .round
        background.lineJoinStyle = .round
        background.lineWidth = lineWidth
        background.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        background.stroke()

        guard percent > 0 else { return }

        context.setStrokeColor(batteryColor(for: status, tone: tone).cgColor)
        let foreground = NSBezierPath()
        foreground.lineCapStyle = .round
        foreground.lineJoinStyle = .round
        foreground.lineWidth = lineWidth
        foreground.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: startAngle - (sweep * percent),
            clockwise: true
        )
        foreground.stroke()
    }

    static func batteryColor(for status: BatteryReader.Status, tone: MenuBarTone) -> NSColor {
        if status.isCharging {
            return NSColor.systemGreen
        }
        if status.percentage >= 0 && status.percentage <= 10 {
            return NSColor.systemRed
        }
        return primaryColor(for: tone)
    }

    private static func drawVolumeDots(context: CGContext, volume: Float32, isMuted: Bool, tone: MenuBarTone) {
        let activeCount = volumeDotCount(volume: volume, isMuted: isMuted)
        let dots: [CGRect] = [
            CGRect(x: 6.75, y: 2.5, width: 2.65, height: 2.65),
            CGRect(x: 10.7, y: 1.1, width: 2.65, height: 2.65),
            CGRect(x: 14.65, y: 1.1, width: 2.65, height: 2.65),
            CGRect(x: 18.6, y: 2.5, width: 2.65, height: 2.65)
        ]

        for (index, dot) in dots.enumerated() {
            let color = index < activeCount ? primaryColor(for: tone) : inactiveColor(for: tone)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: dot)
        }
    }

    static func volumeDotCount(volume: Float32, isMuted: Bool) -> Int {
        guard !isMuted, volume.isFinite else { return 0 }
        return Int(ceil(max(0, min(volume, 1)) * 4))
    }

    private static func drawSystemSymbol(_ symbolName: String, color: NSColor, in rect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
        configured.isTemplate = true

        NSGraphicsContext.saveGraphicsState()
        let image = configured.tinted(with: color) ?? configured
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                            width: size.width, height: size.height)
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func primaryColor(for tone: MenuBarTone) -> NSColor {
        switch tone {
        case .dark:
            return .white
        case .light:
            return .black
        }
    }

    private static func inactiveColor(for tone: MenuBarTone) -> NSColor {
        switch tone {
        case .dark:
            return NSColor(white: 1, alpha: 0.35)
        case .light:
            return NSColor(white: 0, alpha: 0.28)
        }
    }

}

private enum MenuBarTone {
    case dark
    case light
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage? {
        let copy = NSImage(size: size)
        copy.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        rect.fill()
        draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }
}

private final class WiFiReader {
    struct Status {
        let title: String
        let isConnected: Bool
    }

    private var stability = WiFiStability()

    func status() -> Status {
        stability.update(readStatus(), now: ProcessInfo.processInfo.systemUptime)
    }

    private func readStatus() -> Status {
        guard let interface = CWWiFiClient.shared().interface() else {
            return Status(title: "Wi-Fi unavailable", isConnected: false)
        }
        guard interface.powerOn() else {
            return Status(title: "Wi-Fi off", isConnected: false)
        }
        // SSIDs can be redacted by Location Services while the interface is connected.
        // interfaceMode alone is not sufficient here: macOS can leave the interface in
        // station mode briefly after it has disassociated from the access point.
        let mode = interface.interfaceMode()
        let connected = Self.isAssociated(mode: mode, rssi: interface.rssiValue())
        let title = connected ? interface.ssid().map { "Connected: \($0)" } ?? "Connected" : "Not connected"
        return Status(title: title, isConnected: connected)
    }

    static func isAssociated(mode: CWInterfaceMode, rssi: Int) -> Bool {
        (mode == .station || mode == .IBSS) && rssi != 0
    }
}

private struct WiFiStability {
    private var last: WiFiReader.Status?
    private var disconnectedSince: TimeInterval?

    mutating func update(_ sample: WiFiReader.Status, now: TimeInterval) -> WiFiReader.Status {
        if sample.isConnected || last == nil {
            last = sample
            disconnectedSince = nil
            return sample
        }
        if disconnectedSince == nil { disconnectedSince = now }
        if now - disconnectedSince! >= 1 { last = sample }
        return last ?? sample
    }
}

private final class BatteryReader {
    struct Status {
        let summary: String
        let powerSource: String
        let percentage: Int
        let isCharging: Bool
        var isPluggedIn: Bool = false
    }

    func status() -> Status {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let description = sources.compactMap({
                IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
            }).first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType })
        else {
            return Status(
                summary: "No battery information",
                powerSource: "Power source unavailable",
                percentage: -1,
                isCharging: false
            )
        }

        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let percentage = max > 0 ? Int(round(Double(current) / Double(max) * 100)) : 0
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let state = isCharging ? "Charging" : "Not charging"
        let sourceState = description[kIOPSPowerSourceStateKey] as? String ?? "Unknown power source"

        return Status(
            summary: "\(percentage)% - \(state)",
            powerSource: sourceState,
            percentage: percentage,
            isCharging: isCharging,
            isPluggedIn: sourceState == kIOPSACPowerValue
        )
    }
}

private final class VolumeController {
    var canSetVolume: Bool { canSet(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) }
    var canSetMute: Bool { canSet(kAudioDevicePropertyMute) }

    private func canSet(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(defaultOutputDevice(), &address, &settable) == noErr && settable.boolValue
    }

    var outputVolume: Float32 {
        get {
            getScalarProperty(AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )) ?? 0
        }
        set {
            setScalarProperty(
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                value: min(max(newValue, 0), 1)
            )
        }
    }

    var isMuted: Bool {
        get {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let device = defaultOutputDevice()
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
            return status == noErr && muted != 0
        }
        set {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var muted: UInt32 = newValue ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(defaultOutputDevice(), &address, 0, nil, size, &muted)
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func getScalarProperty(_ address: AudioObjectPropertyAddress) -> Float32? {
        var mutableAddress = address
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(defaultOutputDevice(), &mutableAddress, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setScalarProperty(_ address: AudioObjectPropertyAddress, value: Float32) {
        var mutableAddress = address
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(defaultOutputDevice(), &mutableAddress, 0, nil, size, &mutableValue)
    }
}

private let app = NSApplication.shared
if CommandLine.arguments.contains("--build-favicon") {
    let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Assets/favicon-source.svg")
    let outputURL = sourceURL.deletingLastPathComponent().appendingPathComponent("favicon.png")
    guard let source = NSImage(contentsOf: sourceURL) else {
        fatalError("Could not load \(sourceURL.path)")
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Could not create favicon canvas")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 32, height: 32).fill()
    source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32),
                from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render favicon")
    }
    try png.write(to: outputURL)
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    func batteryFixture(_ percentage: Int, charging: Bool = false, pluggedIn: Bool = false) -> BatteryReader.Status {
        .init(summary: "Fixture", powerSource: "Fixture", percentage: percentage, isCharging: charging,
              isPluggedIn: pluggedIn || charging)
    }
    for (value, expected): (Float32, Int) in [(0, 0), (0.01, 1), (0.25, 1), (0.26, 2), (0.5, 2), (0.51, 3), (0.75, 3), (0.76, 4), (1, 4)] {
        precondition(StatusIcon.volumeDotCount(volume: value, isMuted: false) == expected)
        precondition(StatusIcon.volumeDotCount(volume: value, isMuted: true) == 0)
    }
    precondition(StatusIcon.batteryColor(for: batteryFixture(10), tone: .light) == .systemRed)
    precondition(StatusIcon.batteryColor(for: batteryFixture(11), tone: .light) == .black)
    precondition(StatusIcon.batteryColor(for: batteryFixture(5, charging: true), tone: .light) == .systemGreen)
    var notice = CenterNotice()
    let anchor = NSRect(x: 700, y: 876, width: 36, height: 24)
    let hudFrame = VolumeKeyHUD.frame(below: anchor, screen: NSRect(x: 0, y: 0, width: 1440, height: 900))
    precondition(hudFrame.midX == anchor.midX && hudFrame.maxY == anchor.minY - 8)
    let edgeFrame = VolumeKeyHUD.frame(below: NSRect(x: -25, y: 876, width: 24, height: 24),
                                       screen: NSRect(x: -1440, y: 0, width: 1440, height: 900))
    precondition(edgeFrame.maxX <= -8 && edgeFrame.minX >= -1432)
    let hudPreview = VolumeKeyHUD()
    hudPreview.update(volume: 0.625, muted: false, canSetVolume: true, canSetMute: true)
    try hudPreview.writePreview(to: URL(fileURLWithPath: "/tmp/duoicon-volume-hud.png"))
    var fade = CenterTransition()
    fade.set(.wifi, now: 0, reducedMotion: false)
    precondition(!fade.isAnimating(at: 0))
    fade.set(.volume, now: 1, reducedMotion: false)
    let midway = fade.layers(at: 1.045)
    precondition(midway.count == 1 && midway[0].0 == .wifi && midway[0].1 > 0 && midway[0].1 < 1)
    let incoming = fade.layers(at: 1.135)
    precondition(incoming.count == 1 && incoming[0].0 == .volume && incoming[0].1 > 0)
    fade.set(.battery, now: 1.045, reducedMotion: false)
    let interrupted = fade.layers(at: 1.045)
    precondition(abs(interrupted[0].1 - midway[0].1) < 0.0001)
    precondition(fade.layers(at: 1.3).count == 1 && !fade.isAnimating(at: 1.3))
    fade.set(.wifi, now: 2, reducedMotion: true)
    precondition(!fade.isAnimating(at: 2) && fade.layers(at: 2).first?.0 == .wifi)
    var wifiStability = WiFiStability()
    let online = WiFiReader.Status(title: "Connected", isConnected: true)
    let offline = WiFiReader.Status(title: "Not connected", isConnected: false)
    precondition(WiFiReader.isAssociated(mode: .station, rssi: -55))
    precondition(WiFiReader.isAssociated(mode: .IBSS, rssi: -55))
    precondition(!WiFiReader.isAssociated(mode: .station, rssi: 0))
    precondition(!WiFiReader.isAssociated(mode: .none, rssi: -55))
    precondition(wifiStability.update(online, now: 0).isConnected)
    precondition(wifiStability.update(offline, now: 1).isConnected)
    precondition(wifiStability.update(offline, now: 1.5).isConnected)
    precondition(wifiStability.update(online, now: 1.6).isConnected)
    precondition(wifiStability.update(offline, now: 2).isConnected)
    precondition(!wifiStability.update(offline, now: 3).isConnected)
    precondition(wifiStability.update(online, now: 3.1).isConnected)
    precondition(notice.update(volume: 0.5, isMuted: false, battery: batteryFixture(11), now: 0) == .wifi)
    precondition(notice.update(volume: 0.6, isMuted: false, battery: batteryFixture(10), now: 1) == .volume)
    precondition(notice.update(volume: 0.7, isMuted: false, battery: batteryFixture(10), now: 2) == .volume)
    precondition(notice.update(volume: 0.7, isMuted: false, battery: batteryFixture(10), now: 3.9) == .volume)
    precondition(notice.update(volume: 0.7, isMuted: false, battery: batteryFixture(10), now: 4) == .battery)
    precondition(notice.update(volume: 0.7, isMuted: false, battery: batteryFixture(9), now: 6.9) == .battery)
    precondition(notice.update(volume: 0.7, isMuted: false, battery: batteryFixture(9), now: 7) == .wifi)
    precondition(notice.update(volume: 0.7, isMuted: true, battery: batteryFixture(9), now: 8) == .volume)
    precondition(notice.update(volume: 0.7, isMuted: true, battery: batteryFixture(9), now: 10) == .wifi)
    var startupNotice = CenterNotice()
    precondition(startupNotice.update(volume: 0, isMuted: false, battery: batteryFixture(5), now: 0) == .battery)
    precondition(startupNotice.update(volume: 0, isMuted: false, battery: batteryFixture(5, charging: true), now: 1) == .wifi)
    precondition(startupNotice.update(volume: 0, isMuted: false, battery: batteryFixture(-1), now: 2) == .wifi)
    for symbol in ["wifi", "wifi.slash", "speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill", "battery.0percent"] {
        precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
    }
    let sheet = NSImage(size: NSSize(width: 720, height: 240))
    sheet.lockFocus()
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 720, height: 240).fill()
    for (index, percent) in [100, 65, 10, 5, 0, -1].enumerated() {
        let icon = StatusIcon.make(battery: batteryFixture(percent, charging: index == 3, pluggedIn: index == 0),
                                   wifi: .init(title: "Fixture", isConnected: index < 4),
                                   volume: Float32(5 - index) / 5, isMuted: index == 5,
                                   appearance: NSAppearance(named: .aqua)!,
                                   center: index == 1 || index == 5 ? .volume : index == 2 ? .battery : .wifi)
        icon.draw(in: NSRect(x: index * 120, y: 80, width: 120, height: 110))
        ("\(percent)%" as NSString).draw(at: NSPoint(x: index * 120 + 40, y: 40), withAttributes: [.foregroundColor: NSColor.black])
    }
    sheet.unlockFocus()
    let bitmap = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/duoicon-icons.png"))
    print("PASS: volume boundaries, battery colors, notice timing, interruptible transition, reduced motion, system symbols, icon rendering, HUD placement and rendering")
    print("Live state: \(BatteryReader().status().summary), \(WiFiReader().status().title), volume \(VolumeController().outputVolume)")
    exit(0)
}
private let controller = AppController()
app.delegate = controller
app.run()
