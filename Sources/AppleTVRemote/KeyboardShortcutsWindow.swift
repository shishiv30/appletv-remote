import SwiftUI
import AppKit

// MARK: - Key recorder

/// Captures the next keyDown in the settings window and binds it to an action.
@MainActor
private final class ChordRecorder: ObservableObject {
    @Published private(set) var target: RemoteAction?
    @Published var message: String?

    private var monitor: Any?

    func start(for action: RemoteAction) {
        stop()
        target = action
        message = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.target else { return event }
            self.record(event, for: action)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        target = nil
    }

    private func record(_ event: NSEvent, for action: RemoteAction) {
        let chord = KeyChord(event: event)
        // Tab is swallowed by the remote pane; ⌘ chords belong to the menu
        // bar (⌘Q, ⌘W, ⌘,) and never reach the remote pane's keyDown.
        if event.keyCode == 48 {
            message = "Tab can't be bound."
            NSSound.beep()
            return
        }
        if event.modifierFlags.contains(.command) {
            message = "⌘ shortcuts are reserved for the app."
            NSSound.beep()
            return
        }
        if let previous = KeyBindingStore.shared.add(chord, to: action) {
            message = "\(chord.display) moved from “\(previous.title)”."
        }
        stop()
    }
}

// MARK: - SwiftUI view

/// Editor for the remote pane's key bindings, plus trackpad-mode options.
/// Bindings live in `KeyBindingStore`; `KeyCatcherView` reads them live.
struct KeyboardShortcutsView: View {
    @ObservedObject private var store = KeyBindingStore.shared
    @StateObject private var recorder = ChordRecorder()
    @AppStorage(TrackpadSlideMode.defaultsKey) private var slideMode = TrackpadSlideMode.zone.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ForEach(RemoteAction.groups, id: \.title) { group in
                    section(group.title) {
                        ForEach(group.actions) { action in
                            bindingRow(action)
                        }
                    }
                }
                section("Fixed") {
                    fixedRow("Delete", "Backspace (when ATV text input is active)")
                    fixedRow("⌃R", "Return to remote from the apps grid")
                }
                trackpadSection
            }
            .padding(24)
        }
        .onDisappear { recorder.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Keyboard & Trackpad")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Reset to Defaults") {
                    recorder.stop()
                    recorder.message = nil
                    store.resetToDefaults()
                }
            }
            Text("Keys work when the remote pane has focus. Click + and press a key to add a binding.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let message = recorder.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    private func bindingRow(_ action: RemoteAction) -> some View {
        HStack(spacing: 6) {
            Text(action.title)
                .lineLimit(1)
            Spacer(minLength: 8)
            if recorder.target == action {
                Text("Press a key…")
                    .foregroundStyle(Color.accentColor)
                Button("Cancel") { recorder.stop() }
                    .controlSize(.small)
            } else {
                ForEach(store.chords(for: action), id: \.self) { chord in
                    chip(chord, action: action)
                }
                Button {
                    recorder.start(for: action)
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("Add a key for \(action.title)")
                .accessibilityLabel("Add a key for \(action.title)")
            }
        }
        .frame(minHeight: 24)
    }

    private func chip(_ chord: KeyChord, action: RemoteAction) -> some View {
        HStack(spacing: 4) {
            Text(chord.display)
                .font(.system(.body, design: .monospaced).weight(.medium))
            Button {
                store.remove(chord, from: action)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove \(chord.display)")
            .accessibilityLabel("Remove \(chord.display) from \(action.title)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func fixedRow(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 6) {
            Text(description)
            Spacer(minLength: 8)
            Text(keys)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 24)
    }

    private var trackpadSection: some View {
        section("Trackpad mode") {
            Text("Turns the trackpad into the Siri Remote touch surface. The pointer is parked while it is on.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            fixedRow("One finger slide", "D-pad up / down / left / right")
            fixedRow("Two fingers up", "Ring anticlockwise")
            fixedRow("Two fingers down", "Ring clockwise")
            fixedRow("Click", "Select")
            fixedRow("Right-click", "Leave trackpad mode")
            Picker("One-finger slide follows", selection: $slideMode) {
                ForEach(TrackpadSlideMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .padding(.top, 4)
        }
    }
}

// MARK: - Window controller

/// Lazily constructs and shows the Keyboard & Trackpad window. Single shared
/// instance so reopening from the menu raises the existing window instead of
/// stacking duplicates.
@MainActor
final class KeyboardShortcutsWindowController {
    static let shared = KeyboardShortcutsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView:
                KeyboardShortcutsView()
                    .preferredColorScheme(.dark)
            )
            let win = NSWindow(contentViewController: host)
            win.title = "Keyboard & Trackpad"
            win.styleMask = [.titled, .closable, .resizable]
            win.setContentSize(NSSize(width: 520, height: 760))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
