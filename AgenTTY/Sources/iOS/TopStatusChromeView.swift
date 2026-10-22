import Combine
import SwiftUI

enum TopStatusHostSwitchDirection {
    case previous
    case next
}

@safe
struct TopStatusChromeView: View {
    @Environment(TerminalInputRouter.self) private var inputRouter
    @Environment(AgenTTYHostStore.self) private var hostStore
    @Environment(SheetPresentation.self) private var sheetPresentation
    @Environment(KeyboardState.self) private var keyboardState
    let onSelectHost: @MainActor (UUID) -> Void
    let onSelectAdjacentHost: @MainActor (TopStatusHostSwitchDirection) -> Void

    private enum TopCutoutStyle {
        case dynamicIsland
        case notch
        case none
    }

    private enum HostConnectionStatusStyle {
        case noHost
        case disconnected
        case connecting
        case connected

        var subtitle: String {
            switch self {
            case .noHost, .disconnected:
                return "not connected"
            case .connecting:
                return "connecting to..."
            case .connected:
                return "connected to"
            }
        }

        var color: Color {
            switch self {
            case .noHost, .disconnected:
                return .orange.opacity(0.95)
            case .connecting:
                return .yellow.opacity(0.95)
            case .connected:
                return .green.opacity(0.95)
            }
        }

        var showsProgressIndicator: Bool {
            self == .connecting
        }
    }

    // Host picker typography — scaled by chromeScale
    private let hostPrimaryBase: CGFloat = 10.5
    private let hostSecondaryBase: CGFloat = 8.0

    private func hostPrimaryFont(sizeOffset: CGFloat = 0, scale: CGFloat = 1) -> Font {
        .system(size: (hostPrimaryBase + sizeOffset) * scale, weight: .bold, design: .rounded)
    }
    private func hostSecondaryFont(sizeOffset: CGFloat = 0, scale: CGFloat = 1) -> Font {
        .system(size: (hostSecondaryBase + sizeOffset) * scale, weight: .semibold, design: .rounded)
    }

    private let islandAdjacentPadding: CGFloat = 0
    private let hostQuickPickerOuterHorizontalInset: CGFloat = 3
    private let hostQuickPickerTrailingPadding: CGFloat = 5
    private let topChromeCapsuleHeight = AppTheme.chromeCapsuleHeight
    private let hostReferenceSideLaneWidth: CGFloat = 124
    private var chromeForegroundColor: Color { AppTheme.darkModePrimaryText.opacity(0.9) }
    private var menuForegroundColor: Color { AppTheme.primaryText.opacity(0.9) }

    var body: some View {
        GeometryReader { proxy in
            let cutoutStyle = deviceCutoutStyle
            let obstructionWidth = cutoutObstructionWidth(for: cutoutStyle)
            let sideLaneWidth = max(0, (proxy.size.width - obstructionWidth) / 2)
            let hostChromeScale = max(0.75, min(1.0, sideLaneWidth / hostReferenceSideLaneWidth))
            let leadingStatusScale = max(
                0.82,
                min(1.0, sideLaneWidth / leadingStatusReferenceSideLaneWidth(for: cutoutStyle))
            )
            let hostQuickPickerControlWidth = max(
                0,
                sideLaneWidth - (hostQuickPickerOuterHorizontalInset * 2)
            )

            if UIDevice.current.userInterfaceIdiom == .pad {
                HStack(spacing: 12) {
                    menuButton
                    leadingStatus(chromeScale: leadingStatusScale)
                    Spacer(minLength: 0)
                    hostQuickPickerOuterFrame(
                        hostQuickPickerControl(chromeScale: hostChromeScale),
                        width: hostQuickPickerControlWidth
                    )
                    .padding(.trailing, hostQuickPickerTrailingPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        menuButton
                        Spacer(minLength: 2)
                        leadingStatus(chromeScale: leadingStatusScale)
                    }
                    .frame(width: sideLaneWidth, alignment: .leading)

                    Color.clear
                        .frame(width: obstructionWidth)

                    hostQuickPickerOuterFrame(
                        hostQuickPickerControl(chromeScale: hostChromeScale),
                        width: hostQuickPickerControlWidth
                    )
                    .padding(.trailing, hostQuickPickerTrailingPadding)
                    .frame(width: sideLaneWidth, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .foregroundStyle(chromeForegroundColor)
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityLabel("status chrome")
    }

    @ViewBuilder
    private func hostQuickPickerOuterFrame<Content: View>(
        _ content: Content,
        width: CGFloat
    ) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.frame(maxWidth: width, alignment: .trailing)
        } else {
            content.frame(width: width, alignment: .trailing)
        }
    }

    /// Top safe area inset distinguishes notch (44–54pt) from Dynamic Island (59pt+).
    private var deviceTopSafeAreaInset: CGFloat {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first
        else { return 59 }
        return window.safeAreaInsets.top
    }

    /// Top safe area inset distinguishes notch (44–54pt) from Dynamic Island (59pt+).
    private var deviceCutoutStyle: TopCutoutStyle {
        let topInset = deviceTopSafeAreaInset
        if topInset >= 59 { return .dynamicIsland }
        if topInset >= 44 { return .notch }
        return .none
    }

    private func cutoutObstructionWidth(for cutoutStyle: TopCutoutStyle) -> CGFloat {
        switch cutoutStyle {
        case .dynamicIsland:
            return 126
        case .notch:
            return 170
        case .none:
            return 80
        }
    }

    private func leadingStatusReferenceSideLaneWidth(for cutoutStyle: TopCutoutStyle) -> CGFloat {
        switch cutoutStyle {
        case .dynamicIsland:
            // 402pt wide Dynamic Island phones expose ~138pt per side lane.
            return 138
        case .notch:
            // Wider notch phones still have less usable lane width once the cutout is reserved.
            return 129
        case .none:
            return 138
        }
    }

    private func leadingStatus(chromeScale: CGFloat) -> some View {
        TopStatusClockBatteryView(chromeScale: chromeScale)
            .padding(.trailing, islandAdjacentPadding)
    }

    private var menuButton: some View {
        Menu {
            Button("Settings", systemImage: "gear") {
                sheetPresentation.showSettings = true
            }
            .tint(menuForegroundColor)
            Button("Themes", systemImage: "paintpalette") {
                sheetPresentation.showThemes = true
            }
            .tint(menuForegroundColor)
            Button("Hosts", systemImage: "server.rack") {
                sheetPresentation.showHosts = true
            }
            .tint(menuForegroundColor)
            Button("Keys", systemImage: "key.fill") {
                sheetPresentation.showSSHKeys = true
            }
            .tint(menuForegroundColor)
            Button("Tips & Tricks", systemImage: "lightbulb.max") {
                sheetPresentation.showTips = true
            }
            .tint(menuForegroundColor)
            Button(
                keyboardState.isKeyboardHidden ? "Show Keyboard" : "Hide Keyboard",
                systemImage: keyboardState.isKeyboardHidden ? "keyboard" : "keyboard.chevron.compact.down"
            ) {
                if keyboardState.isKeyboardHidden {
                    keyboardState.showKeyboard()
                } else {
                    keyboardState.hideKeyboard()
                }
            }
            .tint(menuForegroundColor)
        } label: {
            ChromeGlassIconLabel(systemImage: "line.3.horizontal")
        }
        .buttonStyle(.glassProminent)
        .tint(AppTheme.controlGlassTint)
        .accessibilityLabel("Menu")
        .padding(.leading, 13)
        .padding(.bottom, 1)
    }

    private func hostQuickPickerControl(chromeScale: CGFloat) -> some View {
        Menu {
            if hostStore.hosts.isEmpty {
                Text("No saved hosts")
            } else {
                ForEach(hostStore.hosts) { host in
                    Button {
                        onSelectHost(host.id)
                    } label: {
                        if host.id == hostStore.activeHostID {
                            Label(host.label, systemImage: "checkmark")
                        } else {
                            Text(host.label)
                        }
                    }
                    .tint(menuForegroundColor)
                }
            }

            Divider()

            Button("Manage Hosts…", systemImage: "list.bullet") {
                sheetPresentation.showHosts = true
            }
            .tint(menuForegroundColor)
        } label: {
            hostQuickPickerLabel(chromeScale: chromeScale)
        }
        .buttonStyle(.glassProminent)
        .tint(AppTheme.controlGlassTint)
        .simultaneousGesture(hostSwipeGesture)
        .padding(.bottom, 1)
        .accessibilityLabel("Host quick picker")
    }

    @ViewBuilder
    private func hostQuickPickerLabel(chromeScale: CGFloat) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            hostStatusLabel(chromeScale: chromeScale)
                .frame(height: topChromeCapsuleHeight, alignment: .leading)
                .padding(.vertical, 0)
                .contentShape(.rect)
        } else {
            hostStatusLabel(chromeScale: chromeScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: topChromeCapsuleHeight, alignment: .leading)
                .padding(.vertical, 0)
                .contentShape(.rect)
        }
    }

    private var hostSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > 28 else { return }
                guard abs(horizontal) > (abs(vertical) * 1.3) else { return }

                let direction: TopStatusHostSwitchDirection =
                    horizontal > 0 ? .previous : .next
                onSelectAdjacentHost(direction)
            }
    }

    private func hostStatusLabel(chromeScale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 3 * chromeScale) {
            hostStatusIndicator(chromeScale: chromeScale)

            hostStatusTextStack(chromeScale: chromeScale)
        }
    }

    @ViewBuilder
    private func hostStatusTextStack(chromeScale: CGFloat) -> some View {
        let content = VStack(alignment: .leading, spacing: -2) {
            Text(connectionSubtitle)
                .font(hostSecondaryFont(sizeOffset: -0.5, scale: chromeScale))
                .minimumScaleFactor(0.7)
                .foregroundStyle(connectionSubtitleColor)

            Text(displayHostLabel)
                .font(hostPrimaryFont(sizeOffset: -2, scale: chromeScale))
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
        }

        if UIDevice.current.userInterfaceIdiom == .pad {
            content
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func hostStatusIndicator(chromeScale: CGFloat) -> some View {
        if hostConnectionStatusStyle.showsProgressIndicator {
            ProgressView()
                .controlSize(.mini)
                .tint(connectionSubtitleColor)
                .frame(maxWidth: 10, maxHeight: .infinity, alignment: .center)
                .padding(.trailing, 2)
        } else {
            Image(systemName: "arrow.left.arrow.right")
                .font(hostSecondaryFont(sizeOffset: 2, scale: chromeScale))
                .foregroundStyle(connectionSubtitleColor)
                .frame(maxWidth: 10, maxHeight: .infinity, alignment: .center)
                .padding(.trailing, 2)
        }
    }

    private var connectionSubtitle: String {
        hostConnectionStatusStyle.subtitle
    }

    private var connectionSubtitleColor: Color {
        hostConnectionStatusStyle.color
    }

    private var displayHostLabel: String {
        hostStore.activeHost?.label ?? "no host"
    }

    private var hostConnectionStatusStyle: HostConnectionStatusStyle {
        guard hostStore.activeHost != nil else { return .noHost }
        switch inputRouter.hostConnectionPhase {
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        }
    }
}

private struct BatterySnapshot {
    var level: Float = 1.0
    var state: UIDevice.BatteryState = .unknown

    static func current() -> Self {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let rawLevel = UIDevice.current.batteryLevel
        return Self(
            level: rawLevel < 0 ? 1.0 : rawLevel,
            state: UIDevice.current.batteryState
        )
    }

    var symbolName: String {
        switch state {
        case .charging, .full:
            return "battery.100.bolt"
        default:
            switch level {
            case ..<0.15: return "battery.0"
            case ..<0.40: return "battery.25"
            case ..<0.65: return "battery.50"
            case ..<0.90: return "battery.75"
            default: return "battery.100"
            }
        }
    }

    var color: Color {
        switch state {
        case .charging, .full:
            return Color.green.opacity(0.95)
        default:
            if level < 0.15 { return Color.red.opacity(0.95) }
            if level < 0.50 { return Color(red: 1.0, green: 0.75, blue: 0.0).opacity(0.95) }
            return Color.green.opacity(0.95)
        }
    }

    var percentageText: String {
        "\(Int(level * 100))%"
    }
}

private struct TopStatusClockBatteryView: View {
    let chromeScale: CGFloat

    @State private var now = Date()
    @State private var battery = BatterySnapshot()

    private let clockTick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let primaryBase: CGFloat = 16.0
    private let secondaryBase: CGFloat = 12.0

    private func primaryFont(sizeOffset: CGFloat = 0) -> Font {
        .system(size: (primaryBase + sizeOffset) * chromeScale, weight: .bold, design: .rounded)
    }

    private func secondaryFont(sizeOffset: CGFloat = 0) -> Font {
        .system(size: (secondaryBase + sizeOffset) * chromeScale, weight: .semibold, design: .rounded)
    }

    private func refreshBattery() {
        battery = BatterySnapshot.current()
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: -1) {
            HStack(alignment: .lastTextBaseline, spacing: 2 * chromeScale) {
                Text(battery.percentageText)
                    .font(secondaryFont(sizeOffset: -0.5))
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(y: -0.2)
                Image(systemName: battery.symbolName)
                    .font(secondaryFont(sizeOffset: 0.5))
            }
            .foregroundStyle(battery.color)

            Text(now, format: .dateTime.hour().minute())
                .font(primaryFont(sizeOffset: 0.5))
                .fixedSize(horizontal: true, vertical: false)
        }
        .onReceive(clockTick) { tick in
            now = tick
        }
        .task {
            refreshBattery()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
        ) { _ in refreshBattery() }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
        ) { _ in refreshBattery() }
        .accessibilityLabel(
            "battery \(battery.percentageText), time \(now.formatted(date: .omitted, time: .shortened))"
        )
    }
}
