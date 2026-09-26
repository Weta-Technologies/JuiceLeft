import AppKit
import Carbon.HIToolbox
import SwiftUI

/// An optional global shortcut that opens (and closes) the panel from any app: Carbon's RegisterEventHotKey, which
/// needs no Accessibility permission and sees nothing but the one combination. Off until one is recorded.
enum HotKey {
    /// One combination as recorded: the virtual key code, the key as it reads on the user's layout, and ⌘⌥⌃⇧.
    struct Spec: Codable, Equatable {
        var keyCode: UInt16
        var key: String          // what the panel shows for the key: "J", "F5", "Space", "→"
        var modifiers: UInt      // NSEvent.ModifierFlags, masked to ⌘⌥⌃⇧

        static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        static let functionKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                                     101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        static let namedKeys: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                                  115: "↖", 119: "↘", 116: "⇞", 121: "⇟"]

        init(keyCode: UInt16, key: String, modifiers: UInt) {
            self.keyCode = keyCode
            self.key = key
            self.modifiers = modifiers
        }

        /// From a key press, or nil when it could steal plain typing.
        init?(event: NSEvent) {
            let mods = event.modifierFlags.intersection(Self.mask)
            guard Self.valid(keyCode: event.keyCode, modifiers: mods) else { return nil }
            let key = Self.functionKeys[event.keyCode] ?? Self.namedKeys[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
            guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains { $0.value < 32 } }) else { return nil }
            self.init(keyCode: event.keyCode, key: key, modifiers: mods.rawValue)
        }

        /// A key needs ⌘, ⌥ or ⌃ with it (⇧ alone would take a plain capital); a function key can stand alone.
        static func valid(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
            functionKeys[keyCode] != nil || !modifiers.intersection([.command, .option, .control]).isEmpty
        }

        var isValid: Bool { Self.valid(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)) }

        /// "⌃⌥J", in the order the menu bar uses.
        var label: String { Self.label(modifiers: NSEvent.ModifierFlags(rawValue: modifiers), key: key) }
        static func label(modifiers: NSEvent.ModifierFlags, key: String) -> String {
            var s = ""
            if modifiers.contains(.control) { s += "⌃" }
            if modifiers.contains(.option) { s += "⌥" }
            if modifiers.contains(.shift) { s += "⇧" }
            if modifiers.contains(.command) { s += "⌘" }
            return s + key
        }

        var carbonModifiers: UInt32 {
            let m = NSEvent.ModifierFlags(rawValue: modifiers)
            var c: UInt32 = 0
            if m.contains(.command) { c |= UInt32(cmdKey) }
            if m.contains(.option) { c |= UInt32(optionKey) }
            if m.contains(.control) { c |= UInt32(controlKey) }
            if m.contains(.shift) { c |= UInt32(shiftKey) }
            return c
        }
    }

    @MainActor static var action: (() -> Void)?
    @MainActor static var recording = false   // the panel's recorder has the keyboard: Esc cancels it rather than closing the panel
    @MainActor private static var ref: EventHotKeyRef?
    @MainActor private static var handler: EventHandlerRef?
    private static let id = EventHotKeyID(signature: 0x4A4C_4654, id: 1)   // "JLFT"

    /// Registers the shortcut (nil = none), replacing any before it. Returns a message when macOS refuses it — another
    /// app, or macOS itself, already has that combination.
    @MainActor @discardableResult
    static func set(_ spec: Spec?) -> String? {
        if let ref { UnregisterEventHotKey(ref); Self.ref = nil }
        guard let spec else { return nil }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? nil : "\(spec.label) is already taken by another app or by macOS — try another shortcut."
    }
}

/// The recorder button: click it, then press the keys. Esc keeps what was there, Delete clears it.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var spec: HotKey.Spec?

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        let binding = _spec
        button.onChange = { binding.wrappedValue = $0 }
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) { button.spec = spec }
}

final class RecorderButton: NSButton {
    var spec: HotKey.Spec? { didSet { if spec != oldValue { refresh() } } }
    var onChange: ((HotKey.Spec?) -> Void)?
    private var keys: Any?   // while recording, every key press comes here first — ahead of ⌘Q and the panel's Esc
    private var recording = false {
        didSet {
            HotKey.recording = recording
            refresh()
            if recording, keys == nil {
                keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    MainActor.assumeIsolated { self?.took(event) }
                    return nil
                }
            } else if !recording, let keys {
                NSEvent.removeMonitor(keys)
                self.keys = nil
            }
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        setAccessibilityLabel("Keyboard shortcut to open the panel")
        refresh()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    deinit {
        if let keys { NSEvent.removeMonitor(keys) }
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: super.intrinsicContentSize.height) }   // one width for every title: nothing shifts
    override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }

    /// The panel closing (or another app coming to the front) ends a recording.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(stopRecording), name: NSWindow.didResignKeyNotification, object: window) }
    }

    @objc private func clicked() {
        if recording { stop() } else { recording = true; window?.makeFirstResponder(self) }
    }

    @objc private func stopRecording() { stop() }

    private func took(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection(HotKey.Spec.mask).isEmpty
        if event.keyCode == 53, plain { return stop() }                    // Esc: keep what was there
        if event.keyCode == 51, plain { onChange?(nil); return stop() }     // Delete: no shortcut
        guard let recorded = HotKey.Spec(event: event) else { return NSSound.beep() }
        onChange?(recorded)
        stop()
    }

    private func stop() {
        recording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func refresh() {
        title = recording ? "Type a shortcut…" : spec?.label ?? "Record…"
        setAccessibilityValue(recording ? "recording" : spec?.label ?? "none")
    }
}
