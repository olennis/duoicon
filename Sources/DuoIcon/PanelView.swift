import AppKit
import SwiftUI

enum Motion {
    static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.74)
    }

    static func snap(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }
}

struct SurfaceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One surface that is hidden, a compact volume island, or the full panel.
/// Switching between island and panel morphs the same rounded shape.
struct SurfaceView: View {
    static let margin = EdgeInsets(top: 6, leading: 24, bottom: 34, trailing: 24)
    static let panelWidth: CGFloat = 300
    static let islandSize = CGSize(width: 236, height: 48)
    static var windowWidth: CGFloat { panelWidth + margin.leading + margin.trailing }

    @ObservedObject var model: PanelModel
    var onHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let island = model.shape == .island
        let shape = RoundedRectangle(cornerRadius: island ? 24 : 18, style: .continuous)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if island {
                    IslandView(model: model).transition(.opacity)
                } else {
                    PanelContentView(model: model).transition(.opacity)
                }
            }
            .frame(width: island ? Self.islandSize.width : Self.panelWidth,
                   height: island ? Self.islandSize.height : nil, alignment: .top)
            // Always take the ideal height, even while the window is still catching up.
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SurfaceHeightKey.self, value: proxy.size.height)
            })
            .shadow(color: .black.opacity(0.26), radius: 16, y: 10)
            .scaleEffect(model.mode == .closed ? 0.88 : 1, anchor: .top)
            .opacity(model.mode == .closed ? 0 : 1)
            Spacer(minLength: 0)
        }
        .padding(Self.margin)
        .frame(width: Self.windowWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(SurfaceHeightKey.self) { onHeight($0) }
        .animation(Motion.spring(reduceMotion), value: model.mode)
        .animation(Motion.spring(reduceMotion), value: model.shape)
        .animation(Motion.spring(reduceMotion), value: model.expanded)
        .animation(Motion.spring(reduceMotion), value: model.showsAccessPrompt)
    }
}

// MARK: - Island (volume key HUD)

private struct IslandView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let s = model.snapshot
        let percent = Int((s.volume * 100).rounded())
        HStack(spacing: 12) {
            Image(systemName: speakerSymbol(volume: s.volume, muted: s.isMuted))
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            MiniTicks(volume: s.volume, muted: s.isMuted)
            RollingText(text: s.isMuted ? L10n.text("Muted") : "\(percent)%", value: Double(percent))
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(width: SurfaceView.islandSize.width, height: SurfaceView.islandSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.onExpandIsland() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Volume"))
        .accessibilityValue(s.isMuted ? L10n.text("Muted") : "\(percent)%")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onExpandIsland() }
    }
}

private struct MiniTicks: View {
    let volume: Float
    let muted: Bool

    var body: some View {
        let lit = muted ? 0 : Int((volume * 16).rounded())
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<16, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? Color.primary : Color.secondary.opacity(0.35))
                    .frame(width: 2, height: index % 4 == 3 ? 12 : 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.16), value: lit)
    }
}

// MARK: - Panel

private struct PanelContentView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 8) {
            if model.showsAccessPrompt {
                AccessCard(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            VolumeCard(model: model)
            WiFiCard(model: model)
            BatteryCard(model: model)
            HStack(spacing: 8) {
                RefreshButton(action: model.onRefresh)
                HoldToQuitButton(action: model.onQuit)
            }
        }
        .padding(10)
        .frame(width: SurfaceView.panelWidth)
    }
}

private struct CardBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.72))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
    }
}

private let tileFill = Color.primary.opacity(0.07)
private let red = Color(nsColor: .systemRed)
private let green = Color(nsColor: .systemGreen)

/// Expand card: a summary row that reveals details below it.
private struct ExpandCard<Leading: View, Meta: View, Content: View, Details: View>: View {
    @ObservedObject var model: PanelModel
    let section: PanelModel.Section
    let title: String
    let subtitle: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var meta: Meta
    @ViewBuilder var content: Content
    @ViewBuilder var details: Details

    var body: some View {
        let open = model.expanded == section
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                leading.frame(width: 32, height: 32)
                Button { model.toggle(section) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.system(size: 13, weight: .semibold))
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        meta
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(open ? L10n.text("Expanded") : L10n.text("Collapsed"))
            }
            .padding(10)
            content
            if open {
                VStack(alignment: .leading, spacing: 6) { details }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 52)
                    .padding([.trailing, .bottom], 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct VolumeCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let s = model.snapshot
        let percent = Int((s.volume * 100).rounded())
        ExpandCard(model: model, section: .volume, title: L10n.text("Volume"),
                   subtitle: s.volumeHUDActive ? L10n.text("Volume key HUD on") : L10n.text("Volume key HUD off")) {
            MuteToggle(muted: s.isMuted, level: speakerLevel(volume: s.volume, muted: s.isMuted),
                       enabled: s.canSetMute, action: model.onToggleMute)
        } meta: {
            RollingText(text: s.isMuted ? L10n.text("Muted") : "\(percent)%", value: Double(percent))
                .font(.system(size: 13, weight: .semibold))
        } content: {
            ExposureSlider(value: s.volume, muted: s.isMuted, enabled: s.canSetVolume,
                           onChange: model.onVolume,
                           onEditing: { model.isDraggingVolume = $0 })
                .padding(.leading, 52)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        } details: {
            Text(L10n.text("⌥⇧ + volume keys: 1/64 steps"))
            RollLink(title: L10n.text("Open Sound Settings")) { model.onOpenSettings(.volume) }
        }
    }
}

private struct WiFiCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let s = model.snapshot
        ExpandCard(model: model, section: .wifi, title: L10n.text("Wi-Fi"), subtitle: s.wifiTitle) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(s.wifiConnected ? Color.accentColor : tileFill)
                Image(systemName: s.wifiConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(s.wifiConnected ? Color.white : Color.primary)
            }
            .animation(.easeOut(duration: 0.2), value: s.wifiConnected)
        } meta: {
            SignalBars(bars: s.wifiConnected ? s.wifiBars : 0)
        } content: {
            EmptyView()
        } details: {
            if s.wifiConnected {
                Text(L10n.format("Signal strength %d of 3", s.wifiBars))
            }
            if s.wifiNeedsLocation {
                Text(L10n.text("Allow Location access to show Wi-Fi name"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            RollLink(title: L10n.text("Open Wi-Fi Settings")) { model.onOpenSettings(.wifi) }
        }
    }
}

private struct BatteryCard: View {
    @ObservedObject var model: PanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = model.snapshot
        let known = s.batteryPercent >= 0
        let low = (0...10).contains(s.batteryPercent) && !s.isCharging
        ExpandCard(model: model, section: .battery, title: L10n.text("Battery"), subtitle: s.powerSource) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tileFill)
                BatteryArc(fraction: 1).stroke(Color.secondary.opacity(0.3),
                                               style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .frame(width: 24, height: 21)
                BatteryArc(fraction: known ? CGFloat(s.batteryPercent) / 100 : 0)
                    .stroke(s.isCharging ? green : low ? red : Color.primary,
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .frame(width: 24, height: 21)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(green)
                    .scaleEffect(s.isCharging ? 1 : 0.4)
                    .opacity(s.isCharging ? 1 : 0)
                    .offset(y: 1)
            }
            .animation(Motion.spring(reduceMotion), value: s.batteryPercent)
            .animation(Motion.spring(reduceMotion), value: s.isCharging)
        } meta: {
            RollingText(text: known ? "\(s.batteryPercent)%" : "—", value: Double(s.batteryPercent))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(low ? red : Color.primary)
        } content: {
            EmptyView()
        } details: {
            Text(s.batterySummary)
            RollLink(title: L10n.text("Open Battery Settings")) { model.onOpenSettings(.battery) }
        }
    }
}

/// Tool approval: explains why Accessibility access is needed before asking for it.
private struct AccessCard: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tileFill)
                    Image(systemName: "keyboard").font(.system(size: 14, weight: .medium))
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Volume HUD Below the Icon")).font(.system(size: 13, weight: .semibold))
                    Text(L10n.text("Press a volume key to show volume controls right below this icon. Requires Accessibility permission."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button(L10n.text("Later")) { model.accessPromptDismissed = true }
                    .buttonStyle(PillButtonStyle(prominent: false))
                Button {
                    model.accessRequest = .waiting
                    model.onRequestAccess()
                } label: {
                    switch model.accessRequest {
                    case .idle: Text(L10n.text("Allow Access"))
                    case .waiting: Text(L10n.text("Waiting for permission…"))
                    case .granted: Label(L10n.text("Allowed"), systemImage: "checkmark")
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: true, tint: model.accessRequest == .granted ? green : .accentColor))
                .disabled(model.accessRequest != .idle)
            }
        }
        .padding(12)
        .background(CardBackground())
    }
}

private struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(prominent ? tint : tileFill))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Controls

/// Exposure slider: 16 notches (every fourth emphasized) that grow near the thumb.
/// It follows the pointer while dragging and springs to the nearest 1/16 on release.
private struct ExposureSlider: View {
    let value: Float
    let muted: Bool
    let enabled: Bool
    let onChange: (Float) -> Void
    let onEditing: (Bool) -> Void

    @State private var dragValue: Float?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let inset: CGFloat = 7

    var body: some View {
        let shown = dragValue ?? value
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - inset * 2)
            let mid = proxy.size.height / 2
            let position = Double(shown) * 16
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0...16, id: \.self) { index in
                        let near = max(0, 1 - abs(Double(index) - position) / 2.6)
                        let on = Double(index) <= position + 0.001
                        Capsule()
                            .fill(on && !muted ? Color.accentColor : Color.secondary)
                            .opacity(on ? (muted ? 0.55 : 0.95) : 0.3 + near * 0.4)
                            .frame(width: 2, height: (index % 4 == 0 ? 10 : 6) + near * 10)
                            .position(x: inset + width * CGFloat(index) / 16, y: mid)
                    }
                }
                .mask(LinearGradient(stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black, location: 0.07),
                    .init(color: .black, location: 0.93),
                    .init(color: .black.opacity(0.5), location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary)
                    .frame(width: 4, height: 26)
                    .position(x: inset + width * CGFloat(shown), y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard enabled else { return }
                    let fraction = Float(min(1, max(0, (gesture.location.x - inset) / width)))
                    if dragValue == nil { onEditing(true) }
                    dragValue = fraction
                    onChange(fraction)
                }
                .onEnded { _ in
                    guard enabled, let current = dragValue else { return }
                    let steps: Float = NSEvent.modifierFlags.contains(.shift) ? 64 : 16
                    onChange((current * steps).rounded() / steps)
                    onEditing(false)
                    withAnimation(Motion.snap(reduceMotion)) { dragValue = nil }
                })
        }
        .frame(height: 34)
        .opacity(enabled ? 1 : 0.4)
        .animation(dragValue == nil ? Motion.snap(reduceMotion) : nil, value: value)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Output volume"))
        .accessibilityValue(muted ? L10n.text("Muted") : "\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
        .focusable(enabled)
        .onMoveCommand { direction in
            switch direction {
            case .right, .up: step(1)
            case .left, .down: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ direction: Float) {
        guard enabled else { return }
        let steps: Float = NSEvent.modifierFlags.contains(.shift) ? 64 : 16
        onChange(min(1, max(0, ((value * steps).rounded() + direction) / steps)))
    }
}

/// Music toggle: the speaker's waves retract and a slash draws in when muted.
private struct MuteToggle: View {
    let muted: Bool
    let level: Int
    let enabled: Bool
    let action: () -> Void

    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.12)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(Motion.spring(false)) { pressed = false }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(muted ? red.opacity(0.16) : tileFill)
                SpeakerGlyph(level: level, muted: muted)
                    .foregroundStyle(muted ? red : Color.primary)
                    .frame(width: 20, height: 20)
                    .scaleEffect(pressed ? 0.82 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(L10n.text("Mute / Unmute"))
        .accessibilityLabel(L10n.text("Mute / Unmute"))
        .accessibilityValue(muted ? L10n.text("Muted") : "")
        .animation(.easeOut(duration: 0.2), value: muted)
    }
}

private struct SpeakerGlyph: View {
    let level: Int
    let muted: Bool

    var body: some View {
        ZStack {
            SpeakerBody().fill()
            ForEach(1...3, id: \.self) { index in
                SpeakerWave(index: index)
                    .trim(from: 0, to: !muted && level >= index ? 1 : 0)
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .animation(.easeOut(duration: 0.24).delay(Double(index - 1) * 0.04), value: level)
                    .animation(.easeOut(duration: 0.24), value: muted)
            }
            SpeakerSlash()
                .trim(from: 0, to: muted ? 1 : 0)
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .animation(.easeOut(duration: 0.24).delay(muted ? 0.06 : 0), value: muted)
        }
    }
}

/// Shapes below are drawn on a 24×24 grid and scaled to their frame.
private struct SpeakerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: 4 * s, y: 9.5 * s))
        path.addLine(to: CGPoint(x: 7 * s, y: 9.5 * s))
        path.addLine(to: CGPoint(x: 11.5 * s, y: 5.7 * s))
        path.addLine(to: CGPoint(x: 11.5 * s, y: 18.3 * s))
        path.addLine(to: CGPoint(x: 7 * s, y: 14.5 * s))
        path.addLine(to: CGPoint(x: 4 * s, y: 14.5 * s))
        path.closeSubpath()
        return path
    }
}

private struct SpeakerWave: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        // start x, half chord, bulge control x (twice the sagitta of the circular arc)
        let (x, half, control): (CGFloat, CGFloat, CGFloat) = [
            (14.5, 2.4, 16.67), (16.8, 4.6, 20.79), (19.1, 6.8, 24.92)
        ][index - 1]
        var path = Path()
        path.move(to: CGPoint(x: x * s, y: (12 - half) * s))
        path.addQuadCurve(to: CGPoint(x: x * s, y: (12 + half) * s), control: CGPoint(x: control * s, y: 12 * s))
        return path
    }
}

private struct SpeakerSlash: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: 3.5 * s, y: 3.5 * s))
        path.addLine(to: CGPoint(x: 20.5 * s, y: 20.5 * s))
        return path
    }
}

/// The menu bar icon's battery arc: 240° over the top, on the same 28×24 grid.
struct BatteryArc: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 28, rect.height / 24)
        let origin = CGPoint(x: rect.midX - 14 * scale, y: rect.midY - 12 * scale)
        let clamped = max(0, min(1, fraction))
        var path = Path()
        guard clamped > 0 else { return path }
        let steps = max(2, Int(60 * clamped))
        for step in 0...steps {
            let angle = (150 + 240 * clamped * CGFloat(step) / CGFloat(steps)) * .pi / 180
            let point = CGPoint(x: origin.x + (14 + 10.2 * cos(angle)) * scale,
                                y: origin.y + (12 + 10.2 * sin(angle)) * scale)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

private struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: [5, 9, 13][index])
            }
        }
        .animation(.easeOut(duration: 0.2), value: bars)
        .accessibilityHidden(true)
    }
}

/// Stat card digits: rolls on macOS 14 and later, cross-fades on macOS 13.
private struct RollingText: View {
    let text: String
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                Text(text).monospacedDigit().contentTransition(.numericText(value: value))
            } else {
                Text(text).monospacedDigit()
            }
        }
        .animation(Motion.spring(reduceMotion), value: text)
    }
}

/// Roll link: the label rolls up to a copy of itself on hover.
private struct RollLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                ZStack {
                    Text(title).offset(y: hovering ? -17 : 0)
                    Text(title).offset(y: hovering ? 0 : 17)
                }
                .frame(height: 17)
                .clipped()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .offset(x: hovering ? 2 : 0, y: hovering ? -2 : 0)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.snap(reduceMotion)) { hovering = inside }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { action() }
    }
}

private struct ShortcutHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tileFill))
            .accessibilityHidden(true)
    }
}

/// Loading to success: spinner while refreshing, then a check.
private struct RefreshButton: View {
    enum Phase { case idle, loading, done }

    let action: () -> Void
    @State private var phase = Phase.idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard phase == .idle else { return }
            phase = .loading
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(Motion.spring(reduceMotion)) { phase = .done }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                    withAnimation(.easeOut(duration: 0.2)) { phase = .idle }
                }
            }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    switch phase {
                    case .idle:
                        Image(systemName: "arrow.clockwise")
                    case .loading:
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    case .done:
                        Image(systemName: "checkmark")
                            .foregroundStyle(green)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(width: 15, height: 15)
                Text(phase == .idle ? L10n.text("Refresh") : phase == .loading ? L10n.text("Refreshing") : L10n.text("Updated"))
                    .foregroundStyle(phase == .done ? green : Color.primary)
                ShortcutHint(text: "⌘R")
            }
            .font(.system(size: 12.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(CardBackground(radius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(L10n.text("Refresh"))
    }
}

/// Hold button: quitting needs a 1.1 second press, so a stray click cannot quit.
/// ⌘Q still quits immediately.
private struct HoldToQuitButton: View {
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        HStack(spacing: 6) {
            Text(holding ? L10n.text("Keep holding") : L10n.text("Hold to Quit"))
            ShortcutHint(text: "⌘Q")
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(holding ? red : Color.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Rectangle().fill(red.opacity(0.16)).frame(width: proxy.size.width * progress)
            }
        }
        .background(CardBackground(radius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 1.1, maximumDistance: 40) {
            holding = false
            progress = 0
            action()
        } onPressingChanged: { pressing in
            holding = pressing
            // The fill is the timer itself, so it stays even with Reduce Motion.
            withAnimation(pressing ? .linear(duration: 1.1) : .easeOut(duration: 0.25)) {
                progress = pressing ? 1 : 0
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Quit DuoIcon"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

// MARK: - Helpers

func speakerLevel(volume: Float, muted: Bool) -> Int {
    muted || volume <= 0 ? 0 : volume <= 0.33 ? 1 : volume <= 0.66 ? 2 : 3
}

func speakerSymbol(volume: Float, muted: Bool) -> String {
    ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"][
        speakerLevel(volume: volume, muted: muted)]
}
