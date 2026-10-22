import CoreGraphics

enum VisualLayering {
    enum AppShell {
        static let terminalContent: Double = 0
        static let keyboardInset: Double = 10
        /// The key grid and the hidden shelf coexist briefly during the
        /// hide/show transition; the sliding grid stays above the shelf.
        static let keyboardSurfaceTransition: Double = 11
        static let dictationStatusOverlay: Double = 50
        static let statusBarBlackout: Double = 150
        static let inAppNotificationBanner: Double = 200
        static let topStatusChrome: Double = 300
        static let accessGate: Double = 400
    }

    enum KeyboardRows {
        private static let baseRowBandUpperBound: Double = 40

        static let bottomRowOverlayHost: Double = 100
        static let modifierHintElevatedRow: Double = 200
        static let keyCalloutElevatedRow: Double = 300

        private static func elevatedRowBandBase(
            _ bandBase: Double,
            rowIndex: Int,
            rowCount: Int
        ) -> Double {
            guard rowCount > 0 else { return bandBase }
            let clampedIndex = min(max(rowIndex, 0), rowCount - 1)
            // Within elevated bands, lower rows get slightly higher depth so
            // upward-extending affordances never slip under the rows above.
            return bandBase + Double(clampedIndex)
        }

        static func baseRow(rowIndex: Int, rowCount: Int) -> Double {
            guard rowCount > 0 else { return 0 }
            let clampedIndex = min(max(rowIndex, 0), rowCount - 1)
            // Preserve a stable top-to-bottom default ordering for non-special rows.
            return baseRowBandUpperBound - Double(clampedIndex)
        }

        static func resolvedZIndex(
            rowIndex: Int,
            rowCount: Int,
            isModifierHintElevated: Bool,
            hasActiveKeyCallout: Bool,
            isBottomRow: Bool
        ) -> Double {
            if hasActiveKeyCallout {
                return elevatedRowBandBase(
                    keyCalloutElevatedRow,
                    rowIndex: rowIndex,
                    rowCount: rowCount
                )
            }
            if isModifierHintElevated {
                return elevatedRowBandBase(
                    modifierHintElevatedRow,
                    rowIndex: rowIndex,
                    rowCount: rowCount
                )
            }
            if isBottomRow {
                return bottomRowOverlayHost
            }
            return baseRow(rowIndex: rowIndex, rowCount: rowCount)
        }
    }

    enum KeyboardKeys {
        static let normal: Double = 0
        static let dpadExpanded: Double = 30
        static let spacebarOverlayHost: Double = 90
        static let keyCalloutActive: Double = 120

        static func resolvedZIndex(isSpacebarOverlayVisible: Bool, hasActiveKeyCallout: Bool) -> Double {
            if hasActiveKeyCallout {
                return keyCalloutActive
            }
            if isSpacebarOverlayVisible {
                return spacebarOverlayHost
            }
            return normal
        }
    }

    enum TerminalSurfaceUIKit {
        static let swipeMask: CGFloat = 100
        static let swipeSnapshot: CGFloat = 200
    }
}
