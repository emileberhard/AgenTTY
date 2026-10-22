import UIKit

@MainActor
protocol TerminalShellSwipeHost: AnyObject {
    func setSurfaceFocus(_ focused: Bool, reason: String)
    func canSwipeShell(in direction: TerminalShellSwipeDirection) -> Bool
    func beginShellSwipePan()
    func updateShellSwipePan(translationX: CGFloat)
    func endShellSwipePan(translationX: CGFloat, velocityX: CGFloat)
}

@MainActor
final class TerminalShellSwipeController: NSObject, UIGestureRecognizerDelegate {
    private weak var host: TerminalShellSwipeHost?
    private weak var panGesture: UIPanGestureRecognizer?

    private var isPanning = false

    init(host: TerminalShellSwipeHost) {
        self.host = host
        super.init()
    }

    func installGestures(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        view.addGestureRecognizer(pan)
        panGesture = pan
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            isPanning = true
            host?.setSurfaceFocus(true, reason: "shellSwipe")
            host?.beginShellSwipePan()
        case .changed:
            if isPanning {
                host?.updateShellSwipePan(translationX: translation.x)
            }
        case .ended, .cancelled, .failed:
            if isPanning {
                isPanning = false
                host?.endShellSwipePan(translationX: translation.x, velocityX: velocity.x)
            }
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)

        guard abs(velocity.x) > abs(velocity.y) else { return false }

        let direction: TerminalShellSwipeDirection = velocity.x < 0 ? .forward : .backward
        return host?.canSwipeShell(in: direction) ?? false
    }
}
