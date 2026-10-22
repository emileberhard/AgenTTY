import UIKit
import GhosttyKit

@MainActor
protocol TerminalTouchSelectionHost: AnyObject {
    var ghosttySurface: ghostty_surface_t? { get }
    var surfaceBounds: CGRect { get }
    func setSurfaceFocus(_ focused: Bool, reason: String)
    func cancelScrollMomentumForSelection()
}

@MainActor
final class TerminalTouchSelectionController: NSObject, UIGestureRecognizerDelegate {
    private struct SelectionSnapshot {
        let text: String
        let anchorPoint: CGPoint?
    }

    private weak var host: TerminalTouchSelectionHost?
    private weak var hostView: UIView?

    private var selectionGestureActive = false
    private var lastGesturePoint: CGPoint?
    private var selectionMenuAnchorPoint: CGPoint?

    private weak var longPressGesture: UILongPressGestureRecognizer?
    private weak var tapGesture: UITapGestureRecognizer?
    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    private let minimumPressDuration: TimeInterval = 0.35
    private let allowableMovement: CGFloat = 36

    init(host: TerminalTouchSelectionHost) {
        self.host = host
        super.init()
    }

    func installInteractions(on view: UIView) {
        hostView = view

        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleLongPressSelection(_:))
        )
        longPress.minimumPressDuration = minimumPressDuration
        longPress.allowableMovement = allowableMovement
        longPress.cancelsTouchesInView = false
        longPress.delegate = self

        let tap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleTapToClearSelection(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.require(toFail: longPress)

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        view.addInteraction(editMenuInteraction)
        tapGesture = tap
        longPressGesture = longPress
    }

    func cancelInteraction() {
        selectionGestureActive = false
        selectionMenuAnchorPoint = nil
        dismissEditMenu()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === tapGesture {
            return hasSelection()
        }
        return true
    }

    @objc private func handleLongPressSelection(_ gesture: UILongPressGestureRecognizer) {
        guard let host else { return }
        guard let view = gesture.view else { return }

        guard let point = TerminalTouchGeometry.clampedSurfacePoint(
            gesture.location(in: view),
            within: host.surfaceBounds
        ) else { return }
        lastGesturePoint = point

        switch gesture.state {
        case .began:
            dismissEditMenu()
            host.cancelScrollMomentumForSelection()
            host.setSurfaceFocus(true, reason: "selectionLongPressBegan")
            beginSelection(at: point)

        case .changed:
            updateSelection(at: point)

        case .ended:
            endSelection(at: point, cancelled: false)

        case .cancelled, .failed:
            endSelection(at: point, cancelled: true)

        default:
            break
        }
    }

    @objc private func handleTapToClearSelection(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard let host else { return }
        guard let view = gesture.view else { return }
        guard hasSelection() else { return }

        guard let point = TerminalTouchGeometry.clampedSurfacePoint(
            gesture.location(in: view),
            within: host.surfaceBounds
        ) else { return }
        lastGesturePoint = point
        selectionMenuAnchorPoint = nil
        dismissEditMenu()

        host.cancelScrollMomentumForSelection()
        host.setSurfaceFocus(true, reason: "selectionTapClear")
        clearSelection(at: point)
        EsmaLog.terminal.info("touch selection cleared by tap")
    }

    private func beginSelection(at point: CGPoint) {
        guard let surface = unsafe host?.ghosttySurface else { return }
        applyMousePosition(point, mods: selectionMods)
        let eventConsumed = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            selectionMods
        )
        // Ghostty returns whether the mouse event was consumed (for example,
        // by mouse reporting), not whether dispatch succeeded.
        // Selection should still proceed when the event is not consumed.
        selectionGestureActive = true
        KeyboardHaptics.touchSelectionStart()
        EsmaLog.terminal.info("touch selection began event_consumed=\(eventConsumed)")
    }

    private func updateSelection(at point: CGPoint) {
        guard selectionGestureActive else { return }
        applyMousePosition(point, mods: selectionMods)
    }

    private func endSelection(at point: CGPoint, cancelled: Bool) {
        guard selectionGestureActive else {
            if !cancelled {
                presentEditMenu(preferredPoint: point)
            }
            return
        }

        guard let surface = unsafe host?.ghosttySurface else {
            selectionGestureActive = false
            return
        }

        applyMousePosition(point, mods: selectionMods)
        _ = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            selectionMods
        )

        selectionGestureActive = false
        if cancelled {
            dismissEditMenu()
            return
        }

        presentEditMenu(preferredPoint: point)
        EsmaLog.terminal.info("touch selection ended")
    }

    private func presentEditMenu(preferredPoint: CGPoint) {
        let snapshot = currentSelectionSnapshot()
        guard snapshot != nil || TerminalClipboard.hasPasteableGeneralContent() else {
            dismissEditMenu()
            return
        }
        guard let anchor = TerminalTouchGeometry.clampedSurfacePoint(
            snapshot?.anchorPoint ?? preferredPoint,
            within: host?.surfaceBounds ?? .zero
        ) else {
            dismissEditMenu()
            return
        }
        selectionMenuAnchorPoint = anchor
        _ = hostView?.becomeFirstResponder()

        let configuration = UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: anchor
        )
        editMenuInteraction.presentEditMenu(with: configuration)
    }

    private func dismissEditMenu() {
        editMenuInteraction.dismissMenu()
    }

    func copyCurrentSelectionToPasteboard() {
        guard let snapshot = currentSelectionSnapshot() else { return }
        UIPasteboard.general.string = snapshot.text
    }

    func selectAll() {
        guard performBindingAction("select_all") else { return }
        if let point = selectionMenuAnchorPoint ?? lastGesturePoint {
            presentEditMenu(preferredPoint: point)
        }
    }

    private func performBindingAction(_ action: String) -> Bool {
        guard let surface = unsafe host?.ghosttySurface else { return false }
        // Swift 6.2 requires the outer acknowledgement; remove this split when releases use Swift 6.4+.
        #if compiler(<6.4)
        return unsafe action.withCString { ptr in
            unsafe ghostty_surface_binding_action(
                surface,
                ptr,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
        #else
        return action.withCString { ptr in
            unsafe ghostty_surface_binding_action(
                surface,
                ptr,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
        #endif
    }

    private func currentSelectionSnapshot() -> SelectionSnapshot? {
        guard let surface = unsafe host?.ghosttySurface else { return nil }
        guard unsafe ghostty_surface_has_selection(surface) else { return nil }

        var text = unsafe ghostty_text_s()
        guard unsafe ghostty_surface_read_selection(surface, &text) else {
            return nil
        }
        defer {
            unsafe ghostty_surface_free_text(surface, &text)
        }

        guard let textPointer = unsafe text.text else { return nil }
        let textLength = unsafe Int(text.text_len)
        guard textLength > 0 else { return nil }

        let bytes = unsafe UnsafeRawBufferPointer(
            start: UnsafeRawPointer(textPointer),
            count: textLength
        )
        let selectionText = unsafe String(decoding: bytes, as: UTF8.self)
        guard !selectionText.isEmpty else { return nil }

        let anchorPoint: CGPoint?
        if unsafe text.tl_px_x >= 0, unsafe text.tl_px_y >= 0 {
            anchorPoint = CGPoint(
                x: unsafe text.tl_px_x,
                y: unsafe text.tl_px_y
            )
        } else {
            anchorPoint = nil
        }

        return SelectionSnapshot(text: selectionText, anchorPoint: anchorPoint)
    }

    private func applyMousePosition(_ point: CGPoint, mods: ghostty_input_mods_e) {
        guard let surface = unsafe host?.ghosttySurface else { return }
        unsafe ghostty_surface_mouse_pos(
            surface,
            Double(point.x),
            Double(point.y),
            mods
        )
    }

    private func clearSelection(at point: CGPoint) {
        guard let surface = unsafe host?.ghosttySurface else { return }
        applyMousePosition(point, mods: noMods)
        _ = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            noMods
        )
        _ = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            noMods
        )
    }

    func hasSelection() -> Bool {
        guard let surface = unsafe host?.ghosttySurface else { return false }
        return unsafe ghostty_surface_has_selection(surface)
    }

    private var selectionMods: ghostty_input_mods_e {
        GHOSTTY_MODS_SHIFT
    }

    private var noMods: ghostty_input_mods_e {
        GHOSTTY_MODS_NONE
    }
}

@MainActor
extension TerminalTouchSelectionController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        guard let hostBounds = host?.surfaceBounds else {
            return .null
        }

        guard let point = TerminalTouchGeometry.clampedSurfacePoint(
            selectionMenuAnchorPoint ?? lastGesturePoint ?? configuration.sourcePoint,
            within: hostBounds
        ) else {
            return .null
        }
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }
}
