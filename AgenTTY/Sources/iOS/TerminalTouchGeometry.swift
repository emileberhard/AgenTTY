import CoreGraphics

@MainActor
enum TerminalTouchGeometry {
    static func clampedSurfacePoint(_ point: CGPoint, within bounds: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        return CGPoint(
            x: min(max(point.x, bounds.minX), max(bounds.minX, bounds.maxX.nextDown)),
            y: min(max(point.y, bounds.minY), max(bounds.minY, bounds.maxY.nextDown))
        )
    }
}
