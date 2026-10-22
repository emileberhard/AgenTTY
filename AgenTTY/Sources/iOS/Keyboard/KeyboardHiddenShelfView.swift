import SwiftUI

/// Bottom strip that replaces the key grid whenever the custom keyboard is not
/// mounted, so the dir/branch chips and shell dots stay on screen.
struct KeyboardHiddenShelfView: View {
    private static let verticalPadding: CGFloat = 2

    var body: some View {
        // `ShellIndicatorView` already sizes itself to `shelfCenteringHeight`,
        // which is derived from the 9pt chip font rather than a magic number.
        ShellIndicatorView()
            .padding(.vertical, Self.verticalPadding)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            // Same rule as the full keyboard: content stays inside the bottom
            // safe area and only the gradient bleeds downward — through the
            // home-indicator zone and, in system-keyboard mode, through the
            // keyboard region so the iOS keyboard sits on the same dark
            // keyboard background instead of the lighter terminal color.
            // A content-level ignoresSafeArea sinks the strip off-screen.
            .background {
                AppTheme.keyboardBackgroundGradient
                    .ignoresSafeArea(.all, edges: .bottom)
            }
    }
}
