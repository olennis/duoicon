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
