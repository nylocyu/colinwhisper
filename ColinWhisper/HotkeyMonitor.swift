import CoreGraphics
import Foundation

/// Keys that can trigger dictation. Only modifiers: they type nothing on their own, so a
/// listen-only tap can watch them without swallowing input.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, leftOption, rightControl, rightShift, fn

    var id: Self { self }

    static var current: TriggerKey {
        UserDefaults.standard.string(forKey: DefaultsKey.triggerKey).flatMap(TriggerKey.init) ?? .rightCommand
    }

    var name: String {
        switch self {
        case .rightCommand: "rechte ⌘-Taste"
        case .rightOption: "rechte ⌥-Taste"
        case .leftOption: "linke ⌥-Taste"
        case .rightControl: "rechte ⌃-Taste"
        case .rightShift: "rechte ⇧-Taste"
        case .fn: "fn-/🌐-Taste"
        }
    }

    // kVK_* from HIToolbox Events.h.
    fileprivate var keyCode: Int64 {
        switch self {
        case .rightCommand: 0x36
        case .rightOption: 0x3D
        case .leftOption: 0x3A
        case .rightControl: 0x3E
        case .rightShift: 0x3C
        case .fn: 0x3F
        }
    }

    /// NX_DEVICE*KEYMASK from IOLLEvent.h: set only while exactly this key is held.
    fileprivate var flag: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .leftOption: 0x20
        case .rightControl: 0x2000
        case .rightShift: 0x04
        case .fn: 0x80_0000  // NX_SECONDARYFNMASK
        }
    }
}

/// Watches the trigger key through a listen-only CGEventTap. The tap only observes and
/// never consumes events, so shortcuts with the same key keep working. Needs Input Monitoring.
final class HotkeyMonitor {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Another key or a click while held: the user is doing a shortcut, not dictating.
    var onInterrupt: () -> Void = {}

    private var tap: CFMachPort?
    private var isDown = false
    private var isActive = false

    /// Device flags of ⌘ ⌥ ⌃ ⇧ on both sides (NX_DEVICE[LR]*KEYMASK).
    private static let modifierFlags: UInt64 = 0x207F

    /// Returns false while Input Monitoring is missing; safe to call again later.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        log.info("event tap installed")
        return true
    }

    fileprivate func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.notice("event tap disabled by system, re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .flagsChanged:
            let trigger = TriggerKey.current
            guard keyCode == trigger.keyCode else { return }
            let down = flags.rawValue & trigger.flag != 0
            guard down != isDown else { return }
            isDown = down
            if down {
                let otherModifier = flags.rawValue & Self.modifierFlags & ~trigger.flag != 0
                isActive = !otherModifier
                if isActive { onPress() }
            } else if isActive {
                isActive = false
                onRelease()
            }

        case .keyDown, .leftMouseDown, .rightMouseDown:
            if isActive {
                isActive = false
                onInterrupt()
            }

        default:
            break
        }
    }
}

private nonisolated func hotkeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // The tap's run loop source lives on the main run loop.
        MainActor.assumeIsolated { monitor.handle(type, keyCode: keyCode, flags: flags) }
    }
    // Always pass the event through unchanged.
    return Unmanaged.passUnretained(event)
}
