import AppKit
import SwiftUI

/// Single-key transport and editing shortcuts that the user can rebind.
///
/// They're caught by an app-wide key monitor rather than SwiftUI's `onKeyPress`, which only fires
/// while the main view has keyboard focus. Clicking any button or slider took that focus away,
/// so Space and Return silently stopped working. They still step aside while a text field is being
/// edited, and in sheets, popovers and dialogs, where Return and Space belong to those controls.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case playPause, record, returnToStart, goToEnd, back, forward, loop, metronome, snap, split, deleteClip, listen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: "Play / Pause"
        case .record: "Record / Stop recording"
        case .returnToStart: "Back to the start"
        case .goToEnd: "Go to the end"
        case .back: "Back 5 seconds"
        case .forward: "Forward 5 seconds"
        case .loop: "Loop on / off"
        case .metronome: "Metronome on / off"
        case .snap: "Snap to beats on / off"
        case .split: "Split at playhead"
        case .deleteClip: "Delete selected clip"
        case .listen: "Listen to input (soundcheck)"
        }
    }

    var detail: String? {
        switch self {
        case .returnToStart: "While recording, this stops the take (keeping it) and goes back. With loop on, it goes to the loop start."
        case .playPause: "While recording, this stops the take."
        default: nil
        }
    }

    var defaultKey: KeyCombo {
        switch self {
        case .playPause: KeyCombo(keyCode: 49, label: "Space")
        case .record: KeyCombo(keyCode: 15, label: "R")
        case .returnToStart: KeyCombo(keyCode: 36, label: "Return")
        case .goToEnd: KeyCombo(keyCode: 36, shift: true, label: "Return")
        case .back: KeyCombo(keyCode: 123, label: "←")
        case .forward: KeyCombo(keyCode: 124, label: "→")
        case .loop: KeyCombo(keyCode: 37, label: "L")
        case .metronome: KeyCombo(keyCode: 40, label: "K")
        case .snap: KeyCombo(keyCode: 5, label: "G")
        case .split: KeyCombo(keyCode: 1, label: "S")
        case .deleteClip: KeyCombo(keyCode: 51, label: "Delete")
        case .listen: KeyCombo(keyCode: 34, label: "I")
        }
    }
}

/// A key plus modifiers. Matched by physical key code, shown by the label captured when it was set.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt = 0
    var label: String

    static let modifierMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    init(keyCode: UInt16, shift: Bool = false, label: String) {
        self.keyCode = keyCode
        self.modifiers = shift ? NSEvent.ModifierFlags.shift.rawValue : 0
        self.label = label
    }

    init(event: NSEvent) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags.intersection(Self.modifierMask).rawValue
        label = Self.names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection(Self.modifierMask).rawValue == modifiers
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }

    private static let names: [UInt16: String] = [
        36: "Return", 76: "Enter", 49: "Space", 48: "Tab", 51: "Delete", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
    ]
}

final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    /// nil = the user removed this shortcut.
    @Published private(set) var bindings: [ShortcutAction: KeyCombo?]
    /// The action waiting for its new key in the Keyboard Shortcuts window.
    @Published var capturing: ShortcutAction?
    @Published var showingEditor = false

    private let defaults: UserDefaults
    private static let storageKey = "shortcuts"
    private var monitor: Any?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var b: [ShortcutAction: KeyCombo?] = [:]
        for a in ShortcutAction.allCases { b[a] = a.defaultKey }
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) {
            for (k, v) in saved { if let a = ShortcutAction(rawValue: k) { b[a] = v } }
        }
        bindings = b
    }

    func key(for action: ShortcutAction) -> KeyCombo? { bindings[action] ?? nil }

    /// Help text with the current key, e.g. "Play / Pause (Space)".
    func hint(_ text: String, _ action: ShortcutAction) -> String {
        key(for: action).map { "\(text) (\($0.display))" } ?? text
    }

    /// Assigns `key`; an action that already had it loses it and is returned so the UI can say so.
    @discardableResult
    func set(_ key: KeyCombo?, for action: ShortcutAction) -> ShortcutAction? {
        var displaced: ShortcutAction?
        if let key {
            for (a, k) in bindings where a != action && k == key { bindings[a] = .some(nil); displaced = a }
        }
        bindings[action] = .some(key)
        save()
        return displaced
    }

    func resetAll() {
        for a in ShortcutAction.allCases { bindings[a] = a.defaultKey }
        save()
    }

    private func save() {
        let out = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(out) { defaults.set(data, forKey: Self.storageKey) }
    }

    func action(for event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { key(for: $0)?.matches(event) == true }
    }

    // MARK: key monitor

    func install(_ session: Session) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak session] event in
            guard let self, let session else { return event }
            if let target = self.capturing {
                if event.keyCode == 53 { self.capturing = nil; return nil }      // Esc cancels
                self.capturing = nil
                let displaced = self.set(KeyCombo(event: event), for: target)
                self.lastDisplaced = displaced.map { ($0, target) }
                return nil
            }
            guard Self.shouldHandle(event), let action = self.action(for: event) else { return event }
            // Holding ← or → keeps moving; holding anything else does it once.
            if !event.isARepeat || action == .back || action == .forward { session.perform(action) }
            return nil
        }
    }

    /// Set when assigning a key took it from another action: (the one that lost it, the one that got it).
    @Published var lastDisplaced: (ShortcutAction, ShortcutAction)?

    /// Only in the main window, with no sheet, popover or dialog in front, and not while typing.
    static func shouldHandle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil, window.sheetParent == nil,
              !(window is NSPanel), !String(describing: type(of: window)).contains("Popover") else { return false }
        return !(window.firstResponder is NSText)      // NSText = the field editor of a text field being typed in
    }
}

extension Session {
    func perform(_ action: ShortcutAction) {
        switch action {
        case .playPause: togglePlay()
        case .record: toggleRecord()
        case .returnToStart: returnToStart()
        case .goToEnd: goToEnd()
        case .back: setPosition(clock.position - 5)
        case .forward: setPosition(clock.position + 5)
        case .loop: toggleLoop()
        case .metronome: project.metronome.toggle()
        case .snap: project.snap.toggle()
        case .split: splitAtPlayhead()
        case .deleteClip: deleteSelectedClip()
        case .listen: toggleListen()
        }
    }
}

/// The Keyboard Shortcuts window: every action, its key, and a button to change or clear it.
struct ShortcutsEditor: View {
    @ObservedObject private var shortcuts = Shortcuts.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "keyboard").foregroundStyle(Theme.purple)
                Text("Keyboard Shortcuts").font(.system(size: 16, weight: .semibold))
            }
            Text("Click a key to change it, then press the new key (with ⇧ ⌃ ⌥ ⌘ if you like). Esc cancels. They work anywhere in the main window except while you're typing a name.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(ShortcutAction.allCases) { action in
                    row(action)
                    if action != ShortcutAction.allCases.last { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            if let (lost, got) = shortcuts.lastDisplaced {
                Text("That key was used by “\(lost.title)”, so it moved to “\(got.title)”. “\(lost.title)” has no key now.")
                    .font(.system(size: 11)).foregroundStyle(Theme.record).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Restore Defaults") { shortcuts.capturing = nil; shortcuts.lastDisplaced = nil; shortcuts.resetAll() }
                Spacer()
                Button("Done") { shortcuts.capturing = nil; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { shortcuts.capturing = nil; shortcuts.lastDisplaced = nil }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let capturing = shortcuts.capturing == action
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title).font(.system(size: 12, weight: .medium))
                if let d = action.detail { Text(d).font(.system(size: 10)).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            Button {
                shortcuts.lastDisplaced = nil
                shortcuts.capturing = capturing ? nil : action
            } label: {
                Text(capturing ? "Press a key…" : (shortcuts.key(for: action)?.display ?? "None"))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(capturing ? .white : Theme.text)
                    .padding(.horizontal, 10).frame(minWidth: 84, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(capturing ? Theme.purple : Theme.background))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
            Button { shortcuts.set(nil, for: action) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).help("Remove this shortcut")
            .opacity(shortcuts.key(for: action) == nil ? 0.3 : 1).disabled(shortcuts.key(for: action) == nil)
            Button { shortcuts.set(action.defaultKey, for: action) } label: {
                Image(systemName: "arrow.uturn.backward").foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain).help("Back to \(action.defaultKey.display)")
            .opacity(shortcuts.key(for: action) == action.defaultKey ? 0.3 : 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}
