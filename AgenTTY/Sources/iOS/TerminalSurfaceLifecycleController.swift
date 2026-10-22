import UIKit
import GhosttyKit

@MainActor
protocol TerminalSurfaceLifecycleHost: AnyObject {
    var ghosttySurface: ghostty_surface_t? { get }
    var isSurfaceAttachedToWindow: Bool { get }
    func sendSyntheticTerminalFocusRefresh(reason: String)
    func handleApplicationWillResignActive()
    func handleApplicationDidEnterBackground()
    func handleApplicationDidBecomeActive()
}

@MainActor
final class TerminalSurfaceLifecycleController {
    private weak var host: TerminalSurfaceLifecycleHost?
    private let onWillDeactivate: () -> Void

    private var lastVisibleState: Bool?
    private var lastFocusedState: Bool?

    init(host: TerminalSurfaceLifecycleHost, onWillDeactivate: @escaping () -> Void) {
        self.host = host
        self.onWillDeactivate = onWillDeactivate
        registerLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func didMoveToWindow() {
        guard let host else { return }
        let attached = host.isSurfaceAttachedToWindow
        setSurfaceFocus(attached, reason: "didMoveToWindow")
        applySurfaceVisibility(attached, reason: "didMoveToWindow")
    }

    func setSurfaceFocus(_ focused: Bool, reason: String) {
        applySurfaceFocus(focused, reason: reason)
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleWillResignActive() {
        host?.handleApplicationWillResignActive()
        handleDeactivation(reason: "willResignActive")
    }

    @objc private func handleDidEnterBackground() {
        handleDeactivation(reason: "didEnterBackground")
        host?.handleApplicationDidEnterBackground()
    }

    @objc private func handleDidBecomeActive() {
        applySurfaceVisibility(true, reason: "didBecomeActive")
        guard let host else { return }
        host.handleApplicationDidBecomeActive()
        let attached = host.isSurfaceAttachedToWindow
        applySurfaceFocus(attached, reason: "didBecomeActive")
        if attached {
            host.sendSyntheticTerminalFocusRefresh(reason: "didBecomeActive")
        }
    }

    private func handleDeactivation(reason: String) {
        onWillDeactivate()
        applySurfaceFocus(false, reason: reason)
        applySurfaceVisibility(false, reason: reason)
    }

    private func applySurfaceVisibility(_ visible: Bool, reason: String) {
        guard let host, let surface = unsafe host.ghosttySurface else { return }
        if lastVisibleState == visible { return }
        lastVisibleState = visible
        unsafe ghostty_surface_set_occlusion(surface, visible)
        EsmaLog.ghostty.info(
            "surface visibility=\(visible) occluded=\(!visible) reason=\(reason, privacy: .public) windowAttached=\(host.isSurfaceAttachedToWindow)"
        )
    }

    private func applySurfaceFocus(_ focused: Bool, reason: String) {
        guard let host, let surface = unsafe host.ghosttySurface else { return }
        if lastFocusedState == focused { return }
        lastFocusedState = focused
        unsafe ghostty_surface_set_focus(surface, focused)
        EsmaLog.ghostty.info(
            "surface focus=\(focused) reason=\(reason, privacy: .public) windowAttached=\(host.isSurfaceAttachedToWindow)"
        )
    }
}
