import UIKit
import GhosttyKit

@MainActor
protocol TerminalTouchScrollHost: AnyObject {
    var ghosttySurface: ghostty_surface_t? { get }
    var screenScale: CGFloat { get }
    var surfaceBounds: CGRect { get }
    func setSurfaceFocus(_ focused: Bool, reason: String)
    func sendTerminalBytes(_ bytes: [UInt8])
}

@MainActor
final class TerminalTouchScrollController: NSObject, UIGestureRecognizerDelegate {
    private struct TapClickAttempt {
        let mods: ghostty_input_mods_e
    }

    enum TapClickMode {
        case plain
        case bypass
    }

    private static let plainTapClickAttempts: [TapClickAttempt] = [
        .init(mods: GHOSTTY_MODS_SUPER),
        .init(mods: GHOSTTY_MODS_NONE)
    ]

    // In mouse-capture/alternate-screen contexts (e.g. tmux), prefer link-bypass
    // combinations before falling back to a normal click.
    private static let bypassTapClickAttemptPrefix: [TapClickAttempt] = [
        .init(
            mods: combinedTapMods(GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_SUPER)
        ),
        .init(
            mods: combinedTapMods(GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_CTRL)
        ),
        .init(mods: GHOSTTY_MODS_SHIFT),
    ]
    private static let bypassTapClickAttempts =
        bypassTapClickAttemptPrefix + plainTapClickAttempts

    private let touchScrollSensitivity: Double = 1.05
    private let touchScrollVelocityBoostMax: Double = 0.08
    private let touchScrollVelocityReference: Double = 2400
    private let touchScrollVelocitySmoothingAlpha: Double = 0.22
    private let touchScrollPanDispatchSpeedPxPerSecond: Double = 12000
    private let touchScrollPanDispatchMinStepPx: Double = 1
    private let touchScrollPanDispatchMaxStepPx: Double = 96
    private let touchScrollMomentumVelocityScale: Double = 1.15
    private let touchScrollMomentumMinStartVerticalGestureSpeedPointsPerSecond: Double = 420
    private let touchScrollMomentumMinStartSpeed: Double = 150
    private let touchScrollMomentumStopSpeed: Double = 40
    private let touchScrollMomentumHighSpeedDecelerationRate: Double = 0.9987
    private let touchScrollMomentumLowSpeedDecelerationRate: Double = 0.9964
    private let touchScrollMomentumLowSpeedThresholdPxPerSecond: Double = 1800
    private let touchScrollMomentumHighSpeedThresholdPxPerSecond: Double = 6800
    private let touchScrollMomentumCarryoverRetention: Double = 0.86
    private let touchScrollMomentumMaxSpeedPxPerSecond: Double = 45000
    private let touchScrollMaxEventDeltaPx: Double = 24

    private weak var host: TerminalTouchScrollHost?
    private weak var tapGesture: UITapGestureRecognizer?
    private weak var panGesture: UIPanGestureRecognizer?
    private var didLogTouchScrollPath = false

    private var panDisplayLink: CADisplayLink?
    private var panLastTimestamp: CFTimeInterval?
    private var pendingPanScrollPxY: Double = 0
    private var isPanGestureActive = false

    private var momentumDisplayLink: CADisplayLink?
    private var momentumLastTimestamp: CFTimeInterval?
    private var momentumVelocityPxPerSecond: CGPoint = .zero
    private var momentumCarryoverPxPerSecond: CGPoint = .zero
    private var lastTouchLocationInView: CGPoint?
    private var filteredPanVelocityPointsPerSecond: CGPoint = .zero
    private var scrollPixelAccumulator: Double = 0

    init(host: TerminalTouchScrollHost) {
        self.host = host
        super.init()
    }

    isolated deinit {
        panDisplayLink?.invalidate()
        panDisplayLink = nil
        panLastTimestamp = nil
        pendingPanScrollPxY = 0

        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        momentumLastTimestamp = nil
        momentumVelocityPxPerSecond = .zero
        momentumCarryoverPxPerSecond = .zero
    }

    func installGestures(on view: UIView) {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.allowedScrollTypesMask = .all
        pan.delegate = self

        tap.require(toFail: pan)

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        tapGesture = tap
        panGesture = pan
    }

    func cancelMomentum() {
        stopPanScrollLoop(flushPending: false)
        stopMomentumScroll()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        cancelMomentum()
        let location = gesture.location(in: gesture.view)
        cacheMousePosition(location)
        logTapDispatchContext(location: location)
        host?.setSurfaceFocus(true, reason: "tap")
        dispatchPrimaryTapClick()
    }

    @objc private func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard unsafe host?.ghosttySurface != nil else { return }
        let location = gesture.location(in: gesture.view)
        updateMousePosition(location)

        switch gesture.state {
        case .began:
            host?.setSurfaceFocus(true, reason: "scrollPanBegan")
            captureMomentumCarryover()
            stopMomentumScroll()
            stopPanScrollLoop(flushPending: false)
            scrollPixelAccumulator = 0
            startPanScrollLoop()
            isPanGestureActive = true
            filteredPanVelocityPointsPerSecond = .zero
            gesture.setTranslation(.zero, in: gesture.view)

        case .changed:
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            let velocity = smoothPanVelocity(gesture.velocity(in: gesture.view))
            if let deltaPx = touchScrollDeltaPx(translation, velocity: velocity) {
                enqueuePanScroll(deltaPx)
                drainPanScrollImmediately()
            }

        case .ended:
            let translation = gesture.translation(in: gesture.view)
            gesture.setTranslation(.zero, in: gesture.view)
            let rawVelocity = gesture.velocity(in: gesture.view)
            let velocity = smoothPanVelocity(rawVelocity)
            if let deltaPx = touchScrollDeltaPx(translation, velocity: velocity) {
                enqueuePanScroll(deltaPx)
                drainPanScrollImmediately()
            }
            isPanGestureActive = false
            startMomentumScroll(initialVelocityPointsPerSecond: rawVelocity)

        case .cancelled, .failed:
            isPanGestureActive = false
            momentumCarryoverPxPerSecond = .zero
            scrollPixelAccumulator = 0
            stopPanScrollLoop(flushPending: false)
            stopMomentumScroll()

        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture else { return true }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }

        let velocity = pan.velocity(in: pan.view)
        let absX = abs(velocity.x)
        let absY = abs(velocity.y)
        guard absX > 0 || absY > 0 else { return true }

        return absY >= absX
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer === tapGesture else { return true }
        guard let surface = unsafe host?.ghosttySurface else { return true }
        let hasSelection = unsafe ghostty_surface_has_selection(surface)
        if hasSelection, EsmaDiagnostics.verboseLoggingEnabled {
            EsmaLog.terminal.debug("touch tap ignored because selection is active")
        }
        return !hasSelection
    }

    private func smoothPanVelocity(_ rawVelocity: CGPoint) -> CGPoint {
        let alpha = touchScrollVelocitySmoothingAlpha
        let previous = filteredPanVelocityPointsPerSecond
        let smoothed = CGPoint(
            x: (previous.x * (1 - alpha)) + (rawVelocity.x * alpha),
            y: (previous.y * (1 - alpha)) + (rawVelocity.y * alpha)
        )
        filteredPanVelocityPointsPerSecond = smoothed
        return smoothed
    }

    private func startPanScrollLoop() {
        guard panDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handlePanTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        panDisplayLink = link
        panLastTimestamp = nil
    }

    private func stopPanScrollLoop(flushPending: Bool) {
        if flushPending {
            flushPendingPanScroll()
        }

        panDisplayLink?.invalidate()
        panDisplayLink = nil
        panLastTimestamp = nil
        pendingPanScrollPxY = 0
        isPanGestureActive = false
    }

    @objc private func handlePanTick(_ link: CADisplayLink) {
        guard unsafe host?.ghosttySurface != nil else {
            stopPanScrollLoop(flushPending: false)
            return
        }

        let dt: CFTimeInterval
        if let lastTimestamp = panLastTimestamp {
            dt = link.timestamp - lastTimestamp
        } else {
            dt = link.duration > 0 ? link.duration : (1 / 120)
        }
        panLastTimestamp = link.timestamp
        guard dt > 0 else { return }
        guard abs(pendingPanScrollPxY) >= 0.0001 else { return }

        let maxStepByDt = touchScrollPanDispatchSpeedPxPerSecond * dt
        let stepLimit = min(
            max(maxStepByDt, touchScrollPanDispatchMinStepPx),
            touchScrollPanDispatchMaxStepPx
        )

        let step = max(min(pendingPanScrollPxY, stepLimit), -stepLimit)
        pendingPanScrollPxY -= step
        sendScrollPixels(CGPoint(x: 0, y: CGFloat(step)))

        if !isPanGestureActive && abs(pendingPanScrollPxY) < 0.0001 {
            stopPanScrollLoop(flushPending: false)
        }
    }

    private func enqueuePanScroll(_ deltaPx: CGPoint) {
        guard deltaPx.y != 0 else { return }
        pendingPanScrollPxY += Double(deltaPx.y)
    }

    private func drainPanScrollImmediately() {
        guard abs(pendingPanScrollPxY) >= 0.0001 else { return }
        let step = max(
            min(pendingPanScrollPxY, touchScrollPanDispatchMaxStepPx),
            -touchScrollPanDispatchMaxStepPx
        )
        pendingPanScrollPxY -= step
        sendScrollPixels(CGPoint(x: 0, y: CGFloat(step)))
    }

    private func flushPendingPanScroll() {
        guard abs(pendingPanScrollPxY) >= 0.0001 else { return }
        sendScrollPixels(CGPoint(x: 0, y: CGFloat(pendingPanScrollPxY)))
    }

    private func touchScrollVelocityBoost(for velocity: CGPoint) -> Double {
        let speed = hypot(Double(velocity.x), Double(velocity.y))
        let normalized = speed / (speed + touchScrollVelocityReference)
        return 1 + (touchScrollVelocityBoostMax * normalized)
    }

    private func touchScrollDeltaPx(_ translation: CGPoint, velocity: CGPoint) -> CGPoint? {
        guard translation != .zero else { return nil }
        if !didLogTouchScrollPath {
            didLogTouchScrollPath = true
            EsmaLog.terminal.info("touch scroll routed directly to SSH as SGR mouse wheel sequences")
        }

        guard let host else { return nil }
        let scrollScale = touchScrollSensitivity * touchScrollVelocityBoost(for: velocity)
        return CGPoint(
            x: 0,
            y: translation.y * host.screenScale * scrollScale
        )
    }

    private func sendScrollPixels(_ deltaPx: CGPoint) {
        guard let surface = unsafe host?.ghosttySurface, let host else { return }
        guard deltaPx.y != 0 else { return }

        let termSize = unsafe ghostty_surface_size(surface)
        let cellHeightPx = Double(termSize.cell_height_px)
        guard cellHeightPx > 0 else { return }

        scrollPixelAccumulator += Double(deltaPx.y)

        let lineCount = Int(scrollPixelAccumulator / cellHeightPx)
        guard lineCount != 0 else { return }
        scrollPixelAccumulator -= Double(lineCount) * cellHeightPx

        // Convert touch position to 1-based cell coordinates for SGR encoding.
        let cellWidthPx = Double(termSize.cell_width_px)
        let scale = Double(host.screenScale)
        let columns = max(Int(termSize.columns), 1)
        let rows = max(Int(termSize.rows), 1)
        let col: Int
        let row: Int
        if let pos = lastTouchLocationInView, cellWidthPx > 0 {
            let rawCol = Int(Double(pos.x) * scale / cellWidthPx) + 1
            let rawRow = Int(Double(pos.y) * scale / cellHeightPx) + 1
            col = min(max(rawCol, 1), columns)
            row = min(max(rawRow, 1), rows)
        } else {
            col = 1
            row = 1
        }

        // SGR mouse wheel: button 64 = wheel up, 65 = wheel down.
        // Positive deltaPx.y (drag down) → scroll up in history → button 64.
        // Negative deltaPx.y (drag up) → scroll down toward recent → button 65.
        let button = lineCount > 0 ? 64 : 65
        let sequence = Array("\u{1b}[<\(button);\(col);\(row)M".utf8)
        let absLines = abs(lineCount)

        for _ in 0..<absLines {
            host.sendTerminalBytes(sequence)
        }
    }

    private func updateMousePosition(_ locationInView: CGPoint) {
        cacheMousePosition(locationInView)
        applyLatestMousePosition()
    }

    private func cacheMousePosition(_ locationInView: CGPoint) {
        guard let host else { return }
        guard let clamped = TerminalTouchGeometry.clampedSurfacePoint(
            locationInView,
            within: host.surfaceBounds
        ) else { return }
        lastTouchLocationInView = clamped
    }

    private func applyLatestMousePosition() {
        guard let surface = unsafe host?.ghosttySurface else { return }
        guard let location = lastTouchLocationInView else { return }
        unsafe ghostty_surface_mouse_pos(surface, Double(location.x), Double(location.y), GHOSTTY_MODS_NONE)
    }

    private func dispatchPrimaryTapClick() {
        guard let surface = unsafe host?.ghosttySurface else { return }
        guard let location = lastTouchLocationInView else { return }

        let mouseCaptured = unsafe ghostty_surface_mouse_captured(surface)
        let alternateScreen = unsafe ghostty_surface_is_alternate_screen(surface)
        let mode: TapClickMode = mouseCaptured || alternateScreen ? .bypass : .plain
        _ = Self.dispatchTapClickAttempts(for: mode) { mods in
            unsafe dispatchMouseClick(
                on: surface,
                location: location,
                mods: mods
            )
        }
    }

    private func dispatchMouseClick(
        on surface: ghostty_surface_t,
        location: CGPoint,
        mods: ghostty_input_mods_e
    ) -> Bool {
        unsafe ghostty_surface_mouse_pos(
            surface,
            Double(location.x),
            Double(location.y),
            mods
        )
        let pressConsumed = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            mods
        )
        let releaseConsumed = unsafe ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            mods
        )
        let consumed = pressConsumed || releaseConsumed
        if EsmaDiagnostics.verboseLoggingEnabled {
            let label = Self.tapClickAttemptLabel(for: mods)
            EsmaLog.terminal.debug(
                "touch tap click attempt mods=\(label, privacy: .public) press_consumed=\(pressConsumed) release_consumed=\(releaseConsumed) consumed=\(consumed)"
            )
        }
        return consumed
    }

    private func logTapDispatchContext(location: CGPoint) {
        guard EsmaDiagnostics.verboseLoggingEnabled else { return }
        guard let surface = unsafe host?.ghosttySurface else {
            EsmaLog.terminal.debug("touch tap dispatch skipped because no ghostty surface exists")
            return
        }
        let mouseCaptured = unsafe ghostty_surface_mouse_captured(surface)
        let alternateScreen = unsafe ghostty_surface_is_alternate_screen(surface)
        EsmaLog.terminal.debug(
            """
            touch tap at x=\(location.x, privacy: .public) y=\(location.y, privacy: .public) \
            mouse_captured=\(mouseCaptured) alternate_screen=\(alternateScreen)
            """
        )
    }

    private static func combinedTapMods(
        _ lhs: ghostty_input_mods_e,
        _ rhs: ghostty_input_mods_e
    ) -> ghostty_input_mods_e {
        ghostty_input_mods_e(lhs.rawValue | rhs.rawValue)
    }

    static func tapClickAttemptModValues(for mode: TapClickMode) -> [UInt32] {
        tapClickAttempts(for: mode).map(\.mods.rawValue)
    }

    @discardableResult
    static func dispatchTapClickAttempts(
        for mode: TapClickMode,
        send: (_ mods: ghostty_input_mods_e) -> Bool
    ) -> ghostty_input_mods_e? {
        for attempt in tapClickAttempts(for: mode) {
            if send(attempt.mods) {
                return attempt.mods
            }
        }
        return nil
    }

    private static func tapClickAttempts(for mode: TapClickMode) -> [TapClickAttempt] {
        switch mode {
        case .plain:
            plainTapClickAttempts
        case .bypass:
            bypassTapClickAttempts
        }
    }

    private static func tapClickAttemptLabel(for mods: ghostty_input_mods_e) -> String {
        let rawValue = mods.rawValue
        if rawValue == combinedTapMods(GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_SUPER).rawValue {
            return "shift+super"
        }
        if rawValue == combinedTapMods(GHOSTTY_MODS_SHIFT, GHOSTTY_MODS_CTRL).rawValue {
            return "shift+ctrl"
        }
        if rawValue == GHOSTTY_MODS_SHIFT.rawValue {
            return "shift"
        }
        if rawValue == GHOSTTY_MODS_SUPER.rawValue {
            return "super"
        }
        if rawValue == GHOSTTY_MODS_NONE.rawValue {
            return "none"
        }

        return "unknown"
    }

    private func startMomentumScroll(initialVelocityPointsPerSecond velocity: CGPoint) {
        stopMomentumScroll()
        guard let host else { return }

        let verticalGestureSpeed = abs(Double(velocity.y))
        guard verticalGestureSpeed >= touchScrollMomentumMinStartVerticalGestureSpeedPointsPerSecond else {
            momentumCarryoverPxPerSecond = .zero
            return
        }

        let scrollScale = touchScrollSensitivity
            * touchScrollVelocityBoost(for: velocity)
            * touchScrollMomentumVelocityScale
        let scale = host.screenScale
        let flickVelocityPxPerSecond = CGPoint(
            x: velocity.x * scale * scrollScale,
            y: velocity.y * scale * scrollScale
        )
        var launchVelocityPxPerSecond = CGPoint(
            x: flickVelocityPxPerSecond.x + momentumCarryoverPxPerSecond.x,
            y: flickVelocityPxPerSecond.y + momentumCarryoverPxPerSecond.y
        )
        momentumCarryoverPxPerSecond = .zero
        launchVelocityPxPerSecond = clampedMomentumVelocity(launchVelocityPxPerSecond)

        let launchSpeed = hypot(
            Double(launchVelocityPxPerSecond.x),
            Double(launchVelocityPxPerSecond.y)
        )
        guard launchSpeed >= touchScrollMomentumMinStartSpeed else {
            return
        }

        momentumVelocityPxPerSecond = launchVelocityPxPerSecond
        momentumLastTimestamp = nil
        scrollPixelAccumulator = 0

        let link = CADisplayLink(target: self, selector: #selector(handleMomentumTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumDisplayLink = link
    }

    private func stopMomentumScroll() {
        guard momentumDisplayLink != nil else { return }
        momentumDisplayLink?.invalidate()
        momentumDisplayLink = nil
        momentumLastTimestamp = nil
        momentumVelocityPxPerSecond = .zero
    }

    private func captureMomentumCarryover() {
        guard momentumDisplayLink != nil else {
            momentumCarryoverPxPerSecond = .zero
            return
        }
        momentumCarryoverPxPerSecond = CGPoint(
            x: momentumVelocityPxPerSecond.x * touchScrollMomentumCarryoverRetention,
            y: momentumVelocityPxPerSecond.y * touchScrollMomentumCarryoverRetention
        )
    }

    private func clampedMomentumVelocity(_ velocity: CGPoint) -> CGPoint {
        let speed = hypot(Double(velocity.x), Double(velocity.y))
        guard speed > touchScrollMomentumMaxSpeedPxPerSecond else { return velocity }
        let clampScale = touchScrollMomentumMaxSpeedPxPerSecond / speed
        return CGPoint(
            x: velocity.x * clampScale,
            y: velocity.y * clampScale
        )
    }

    private func momentumDecayRate(forSpeed speed: Double) -> Double {
        let thresholdRange = touchScrollMomentumHighSpeedThresholdPxPerSecond - touchScrollMomentumLowSpeedThresholdPxPerSecond
        guard thresholdRange > 0 else { return touchScrollMomentumHighSpeedDecelerationRate }
        let progress = (speed - touchScrollMomentumLowSpeedThresholdPxPerSecond) / thresholdRange
        let clampedProgress = min(max(progress, 0), 1)
        return touchScrollMomentumLowSpeedDecelerationRate
            + ((touchScrollMomentumHighSpeedDecelerationRate - touchScrollMomentumLowSpeedDecelerationRate) * clampedProgress)
    }

    @objc private func handleMomentumTick(_ link: CADisplayLink) {
        guard unsafe host?.ghosttySurface != nil else {
            stopMomentumScroll()
            return
        }

        let dt: CFTimeInterval
        if let lastTimestamp = momentumLastTimestamp {
            dt = link.timestamp - lastTimestamp
        } else {
            dt = link.duration > 0 ? link.duration : (1 / 120)
        }
        momentumLastTimestamp = link.timestamp
        guard dt > 0 else { return }

        let deltaPx = CGPoint(
            x: momentumVelocityPxPerSecond.x * dt,
            y: momentumVelocityPxPerSecond.y * dt
        )
        sendScrollPixels(deltaPx)

        let speedBeforeDecay = hypot(
            Double(momentumVelocityPxPerSecond.x),
            Double(momentumVelocityPxPerSecond.y)
        )
        let decayRate = momentumDecayRate(forSpeed: speedBeforeDecay)
        let decay = pow(decayRate, dt * 1000)
        momentumVelocityPxPerSecond.x *= decay
        momentumVelocityPxPerSecond.y *= decay

        let speed = hypot(
            Double(momentumVelocityPxPerSecond.x),
            Double(momentumVelocityPxPerSecond.y)
        )
        if speed < touchScrollMomentumStopSpeed {
            stopMomentumScroll()
        }
    }
}
