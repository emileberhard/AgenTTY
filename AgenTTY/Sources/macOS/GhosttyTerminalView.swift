import AppKit
import SwiftUI
import GhosttyKit

struct GhosttyTerminalViewMacOS: View {
    let ghostty: GhosttyRuntime

    var body: some View {
        GeometryReader { geo in
            GhosttySurfaceRepresentableMacOS(
                ghostty: ghostty,
                size: geo.size
            )
        }
    }
}

private struct GhosttySurfaceRepresentableMacOS: NSViewRepresentable {
    let ghostty: GhosttyRuntime
    let size: CGSize

    func makeNSView(context: Context) -> TerminalSurfaceViewMacOS {
        let view = TerminalSurfaceViewMacOS(ghostty: ghostty)
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: TerminalSurfaceViewMacOS, context: Context) {
        nsView.sizeDidChange(size)
    }
}

@MainActor
final class TerminalSurfaceViewMacOS: NSView, GhosttySurfaceProvider {
    private let ghostty: GhosttyRuntime
    private var bridge: TerminalBridge?
    private var focused = false

    private(set) var ghosttySurface: ghostty_surface_t?

    init(ghostty: GhosttyRuntime) {
        self.ghostty = ghostty
        super.init(frame: .zero)

        wantsLayer = true

        guard let surface = ghostty.makeSurface(for: self) else {
            fatalError("failed to create ghostty surface")
        }

        self.ghosttySurface = surface
        self.bridge = TerminalBridge(
            runtime: ghostty,
            surface: surface,
            keyMaterialStore: AgenTTYSSHKeyMaterialStore(flavor: .main),
            passwordStore: AgenTTYSSHPasswordStore(flavor: .main),
            hostStore: AgenTTYHostStore(flavor: .main),
            trustedHostKeyStore: AgenTTYTrustedHostKeyStore(
                userDefaults: AgenTTYSharedDefaults.store,
                flavor: .main
            ),
            analyticsClient: AgenTTYAnalyticsClient(flavor: .main)
        )
        ghostty.tick()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        bridge = nil
        if let surface = ghosttySurface {
            ghostty_surface_free(surface)
        }
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface = ghosttySurface else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)

        let backing = convertToBacking(size)
        let widthPx = UInt32(max(Int(backing.width), 1))
        let heightPx = UInt32(max(Int(backing.height), 1))

        ghostty_surface_set_size(surface, widthPx, heightPx)

        let terminalSize = ghostty_surface_size(surface)
        bridge?.updateWindowSize(
            columns: Int(terminalSize.columns),
            rows: Int(terminalSize.rows),
            widthPx: Int(widthPx),
            heightPx: Int(heightPx)
        )
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        focusDidChange(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        focusDidChange(false)
        return true
    }

    private func focusDidChange(_ focused: Bool) {
        guard let surface = ghosttySurface else { return }
        guard self.focused != focused else { return }

        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    override func keyDown(with event: NSEvent) {
        _ = keyAction(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func keyAction(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface = ghosttySurface else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = Self.ghosttyMods(event.modifierFlags.subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        keyEvent.text = nil

        if action != GHOSTTY_ACTION_RELEASE, let text = event.ghosttyCharacters, !text.isEmpty {
            let bytes = Array(text.utf8)
            if let first = bytes.first, first >= 0x20 {
                return text.withCString { ptr in
                    keyEvent.text = ptr
                    return ghostty_surface_key(surface, keyEvent)
                }
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

private extension NSEvent {
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
