import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OSLog

/// Number keys that select a tab in the results panel.
enum ResultsTabShortcut {
    /// Only the first nine tabs have a number key.
    static let tabLimit = 9

    private static let numberRowKeyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]
    private static let keypadKeyCodes = [
        kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
        kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9
    ]

    /// The zero-based tab for a number key. Keys are matched by position, so layouts that need
    /// Shift to type digits behave the same way.
    static func tabIndex(forKeyCode keyCode: Int64) -> Int? {
        let keyCode = Int(keyCode)
        return numberRowKeyCodes.firstIndex(of: keyCode) ?? keypadKeyCodes.firstIndex(of: keyCode)
    }

    /// Whether exactly the recognition modifiers are held. Plain number keys never match, because
    /// they belong to whatever the user is typing.
    static func matches(_ flags: CGEventFlags, modifiers: [RecognitionModifier]) -> Bool {
        !modifiers.isEmpty && self.modifiers(in: flags) == Set(modifiers)
    }

    static func matches(_ flags: NSEvent.ModifierFlags, modifiers: [RecognitionModifier]) -> Bool {
        !modifiers.isEmpty && self.modifiers(in: flags) == Set(modifiers)
    }

    static func modifiers(in flags: CGEventFlags) -> Set<RecognitionModifier> {
        var modifiers = Set<RecognitionModifier>()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.globe) }
        return modifiers
    }

    static func modifiers(in flags: NSEvent.ModifierFlags) -> Set<RecognitionModifier> {
        var modifiers = Set<RecognitionModifier>()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.globe) }
        return modifiers
    }
}

/// Takes tab shortcuts before they reach the app under the pointer. The results panel doesn't
/// become key during a hover, so AppKit never delivers these keys to Hovery.
///
/// Every key press on the system waits for an active event tap, so the tap only runs while the
/// shortcut's modifiers are held. Modifier changes come from passive event monitors, which never
/// delay input. The tap needs the Accessibility permission, which hover recognition requires.
@MainActor
final class ResultsTabShortcutMonitor {
    /// Returns `true` when the key press selected a tab and must not reach other apps.
    var keyDownHandler: ((_ keyCode: Int64, _ flags: CGEventFlags) -> Bool)?
    var modifierFlagsDidChange: ((NSEvent.ModifierFlags) -> Void)?

    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "ResultsTabShortcuts")
    /// The test host must never take key presses from the user's other apps.
    private let isAvailable = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    nonisolated(unsafe) private var tap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private var isCapturingKeys = false
    private var didReportMissingTap = false
    /// Key presses that selected a tab. Their key-up events are withheld too, so the app under
    /// the pointer never sees half a key press.
    private var consumedKeyCodes = Set<Int64>()

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    /// Reports modifier changes, from Hovery and from other apps, until `stop()`.
    func watchModifiers() {
        guard isAvailable, globalModifierMonitor == nil else { return }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.modifierFlagsDidChange?(flags)
            }
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifierFlagsDidChange?(event.modifierFlags)
            return event
        }
    }

    func stop() {
        setCapturingKeys(false)
        for monitor in [globalModifierMonitor, localModifierMonitor].compactMap(\.self) {
            NSEvent.removeMonitor(monitor)
        }
        globalModifierMonitor = nil
        localModifierMonitor = nil
    }

    func setCapturingKeys(_ capturing: Bool) {
        guard isAvailable, capturing != isCapturingKeys else { return }
        if capturing, tap == nil, !installTap() { return }
        isCapturingKeys = capturing
        consumedKeyCodes.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: capturing)
        }
    }

    fileprivate func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isCapturingKeys, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        case .keyDown where isCapturingKeys:
            guard keyDownHandler?(keyCode, flags) == true else { return false }
            consumedKeyCodes.insert(keyCode)
            return true
        case .keyUp:
            return consumedKeyCodes.remove(keyCode) != nil
        default:
            return false
        }
    }

    private func installTap() -> Bool {
        let events: [CGEventType] = [.keyDown, .keyUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: resultsTabShortcutTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !didReportMissingTap {
                didReportMissingTap = true
                logger.error("Could not install the results tab shortcut event tap")
            }
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        runLoopSource = source
        return true
    }
}

private func resultsTabShortcutTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<ResultsTabShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.rawValue
    // The tap's run loop source is scheduled on the main run loop.
    let consumed = MainActor.assumeIsolated {
        monitor.handle(type, keyCode: keyCode, flags: CGEventFlags(rawValue: flags))
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
