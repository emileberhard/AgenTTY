#if DEBUG
import SwiftUI
import UIKit

enum CaptureScreen: String, CaseIterable {
    case terminal
    case keyboardHidden = "keyboard-hidden"
    case switchHosts = "switch-hosts"
    case hosts
    case hostAdd = "host-add"
    case hostManual = "host-manual"
    case hostPairing = "host-pairing"
    case hostEdit = "host-edit"
    case keys
    case themes
    case settings
    case tips

    static func named(_ list: String?) throws -> [CaptureScreen] {
        guard let list else {
            return allCases
        }
        let screens = try list.split(separator: ",", omittingEmptySubsequences: false).map { id in
            guard let screen = CaptureScreen(rawValue: String(id)) else {
                throw CaptureError("there is no screen \"\(id)\"; the screens are \(allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return screen
        }
        guard Set(screens).count == screens.count else {
            throw CaptureError("\(list) names a screen more than once")
        }
        return screens
    }
}

private struct CaptureScene: View {
    let fixture: CaptureFixture
    let ghostty: GhosttyRuntime
    @State private var appDelegate = AgenTTYAppDelegate()
    @State private var inputRouter: TerminalInputRouter
    @State private var keyboard: KeyboardState
    @State private var sheets: SheetPresentation
    @State private var shellState: ShellIndicatorState

    init(_ screen: CaptureScreen, fixture: CaptureFixture, ghostty: GhosttyRuntime) {
        self.fixture = fixture
        self.ghostty = ghostty
        _shellState = State(initialValue: fixture.shellState(for: screen))
        let sheets = SheetPresentation()
        switch screen {
        case .terminal, .keyboardHidden, .switchHosts: break
        case .hosts: sheets.showHosts = true
        case .hostAdd: sheets.presentHosts(route: .addSetupMethod)
        case .hostManual: sheets.presentHosts(route: .addManual)
        case .hostPairing: sheets.presentHosts(route: .addAutomatic)
        case .hostEdit: sheets.presentHosts(route: .edit(fixture.workstation))
        case .keys: sheets.showSSHKeys = true
        case .themes: sheets.showThemes = true
        case .settings: sheets.showSettings = true
        case .tips: sheets.showTips = true
        }
        _sheets = State(initialValue: sheets)
        let keyboard = KeyboardState()
        if screen == .keyboardHidden || screen == .switchHosts {
            keyboard.hideKeyboard()
        }
        _keyboard = State(initialValue: keyboard)
        let inputRouter = TerminalInputRouter()
        inputRouter.lifetimeAccessController = fixture.lifetimeAccessController
        _inputRouter = State(initialValue: inputRouter)
    }

    var body: some View {
        AgenTTYMainWindowView(
            appDelegate: appDelegate,
            ghostty: ghostty,
            keyStore: fixture.keyStore,
            passwordStore: fixture.passwordStore,
            trustedHostKeyStore: fixture.trustedHostKeyStore,
            inputRouter: inputRouter,
            shellState: shellState,
            keyboardState: keyboard,
            hostStore: fixture.hostStore,
            hostReachabilityMonitor: fixture.reachabilityMonitor,
            sheetPresentation: sheets,
            themeToken: fixture.themeToken,
            themeNonce: fixture.themeToken.nonce,
            terminalFontSize: TerminalFontSizeSetting.defaultValue,
            keyboardInputMode: .defaultValue,
            lifetimeAccessController: fixture.lifetimeAccessController,
            analyticsClient: fixture.analyticsClient,
            shortcutExecutionContext: fixture.shortcutExecutionContext
        )
    }
}

@MainActor
final class CaptureFixture {
    private struct Machine {
        let label: String
        let address: String
        let session: [String]
    }

    private static let suiteName = "dev.tuist.agentty.capture"
    private static let machines = [
        Machine(label: "workstation", address: "workstation.local", session: [
            "\u{1B}[1;35m╭─ Claude Code ───────────────╮\u{1B}[0m",
            "\u{1B}[1;35m│\u{1B}[0m  AgenTTY release workspace    \u{1B}[1;35m│\u{1B}[0m",
            "\u{1B}[1;35m╰──────────────────────────────╯\u{1B}[0m",
            "",
            "\u{1B}[1;36m›\u{1B}[0m Finish the App Store release.",
            "",
            "\u{1B}[2m⏺ I’ll build and verify the full\u{1B}[0m",
            "\u{1B}[2m  iPhone + iPad screenshot flow.\u{1B}[0m",
            "",
            "\u{1B}[1;32m✓\u{1B}[0m Captured the production UI",
            "\u{1B}[1;32m✓\u{1B}[0m Composed the App Store slides",
            "\u{1B}[1;32m✓\u{1B}[0m Verified every output size",
            "",
            "\u{1B}[1;34mReady for App Review.\u{1B}[0m",
        ]),
        Machine(label: "laptop", address: "laptop.local", session: [
            "\u{1B}[1;36m>_ Codex\u{1B}[0m \u{1B}[2m(workspace: ~/projects/site)\u{1B}[0m",
            "",
            "\u{1B}[1;36m›\u{1B}[0m Fix the flaky checkout test.",
            "",
            "\u{1B}[2m• Ran\u{1B}[0m bun test checkout",
            "\u{1B}[2m  └ 1 failed: totals round twice\u{1B}[0m",
            "",
            "\u{1B}[2m• Edited\u{1B}[0m src/cart/total.ts \u{1B}[32m+4\u{1B}[0m \u{1B}[31m-6\u{1B}[0m",
            "",
            "\u{1B}[1;32m✓\u{1B}[0m 42 tests pass",
        ]),
        Machine(label: "build-server", address: "192.0.2.24", session: []),
    ]

    static func terminalOutput(for host: AgenTTYHost?) -> String? {
        guard CaptureView.directory != nil,
              let machine = machines.first(where: { $0.address == host?.address }) else {
            return nil
        }
        return "\u{1B}c" + machine.session.joined(separator: "\r\n")
    }

    let hostStore: AgenTTYHostStore
    let keyStore: AgenTTYSSHKeyStore
    let passwordStore: AgenTTYSSHPasswordStore
    let trustedHostKeyStore: AgenTTYTrustedHostKeyStore
    let analyticsClient: AgenTTYAnalyticsClient
    let reachabilityMonitor = AgenTTYHostReachabilityMonitor()
    let lifetimeAccessController: AgenTTYLifetimeAccessController
    let shortcutExecutionContext: AgenTTYShortcutExecutionContext
    let themeToken = AppThemeToken()
    let workstation: AgenTTYHost
    let laptop: AgenTTYHost

    init() throws {
        let flavor = AgenTTYBuildFlavor.current()
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
            throw CaptureError("could not open the \(Self.suiteName) defaults")
        }
        let materialStore = AgenTTYSSHKeyMaterialStore(flavor: flavor)
        let previousKeys = AgenTTYSSHKeyStore(userDefaults: defaults, flavor: flavor, materialStore: materialStore)
        for key in previousKeys.keys {
            if case .failure(let error) = previousKeys.deleteKey(id: key.id) {
                throw CaptureError("could not delete the previous capture key: \(error)")
            }
        }
        defaults.removePersistentDomain(forName: Self.suiteName)

        hostStore = AgenTTYHostStore(userDefaults: defaults, flavor: flavor)
        keyStore = AgenTTYSSHKeyStore(userDefaults: defaults, flavor: flavor, materialStore: materialStore)
        passwordStore = AgenTTYSSHPasswordStore(flavor: flavor)
        trustedHostKeyStore = AgenTTYTrustedHostKeyStore(userDefaults: defaults, flavor: flavor)
        analyticsClient = AgenTTYAnalyticsClient(flavor: flavor)
        lifetimeAccessController = AgenTTYLifetimeAccessController(flavor: flavor, localMainInstallUnlockEnabled: true)
        shortcutExecutionContext = AgenTTYShortcutExecutionContext(
            hostStore: hostStore,
            keyMaterialStore: materialStore,
            passwordStore: passwordStore,
            trustedHostKeyStore: trustedHostKeyStore,
            lifetimeAccessController: lifetimeAccessController
        )

        guard let keyID = keyStore.defaultGeneratedKeyID(named: "agentty@iphone") else {
            throw CaptureError("could not generate the capture SSH key")
        }
        let hostStore = hostStore
        let hostIDs = try Self.machines.map { machine in
            guard let draft = AgenTTYHostDraft(
                label: machine.label,
                address: machine.address,
                port: AgenTTYConnection.defaultPort,
                username: "developer",
                authentication: .key(keyID)
            ) else {
                throw CaptureError("invalid capture host \(machine.label)")
            }
            return hostStore.addHost(draft)
        }
        guard let workstation = hostStore.hosts.first(where: { $0.id == hostIDs[0] }),
              let laptop = hostStore.hosts.first(where: { $0.id == hostIDs[1] }) else {
            throw CaptureError("the capture hosts were not saved")
        }
        self.workstation = workstation
        self.laptop = laptop
        var reachable = HostListReachabilityTracker()
        reachable.recordSuccess()
        reachabilityMonitor.updateHosts(hostStore.hosts)
        reachabilityMonitor.seedPreviewTrackers(Dictionary(uniqueKeysWithValues: hostIDs.map { ($0, reachable) }))
    }

    func shellState(for screen: CaptureScreen) -> ShellIndicatorState {
        let state = ShellIndicatorState()
        let shells = screen == .switchHosts
            ? [(1, "~/projects/site", "fix-checkout")]
            : [(1, "~/projects/agentty", "main"), (2, "~/projects/agentty", "release"), (3, "~/projects/backend", "main")]
        state.update(windowCount: shells.count, activePosition: 0, windowIds: shells.map(\.0))
        for (id, directory, branch) in shells {
            state.updateWindowContext(windowID: id, workingDirectoryPath: directory, branchName: branch)
        }
        return state
    }
}

struct CaptureView: View {
    static let directory = ProcessInfo.processInfo.environment["AGENTTY_CAPTURE"].map { URL(filePath: $0) }

    let directory: URL
    let ghostty: GhosttyRuntime
    @State private var fixture: CaptureFixture?
    @State private var screen: CaptureScreen?
    @State private var appeared = AsyncStream.makeStream(of: CaptureScreen.self)
    @State private var cleared = AsyncStream.makeStream(of: Void.self)

    var body: some View {
        Group {
            if let screen, let fixture {
                CaptureScene(screen, fixture: fixture, ghostty: ghostty)
                    .transaction { $0.disablesAnimations = true }
                    .onAppear { appeared.continuation.yield(screen) }
            } else {
                Color.black.ignoresSafeArea().onAppear { cleared.continuation.yield(()) }
            }
        }
        .id(screen)
        .task {
            do {
                try await capture()
                exit(0)
            } catch {
                print("capture failed: \(error)")
                exit(1)
            }
        }
    }

    private func capture() async throws {
        let screens = try CaptureScreen.named(ProcessInfo.processInfo.environment["AGENTTY_CAPTURE_SCREENS"])
        try FileManager.default.createDirectory(at: directory.appending(path: "jpg"), withIntermediateDirectories: true)
        UIView.setAnimationsEnabled(false)
        let window = try await keyWindow()
        let theme = switch ProcessInfo.processInfo.environment["AGENTTY_CAPTURE_APPEARANCE"] {
        case "light": "Catppuccin Latte"
        case "dark": AgenTTYThemeSelection.defaultThemeName
        default: throw CaptureError("invalid capture appearance")
        }
        AgenTTYSharedDefaults.store.set(theme, forKey: AgenTTYThemeSelection.storageKey)
        guard ghostty.applyTheme(named: theme) else {
            throw CaptureError("could not apply the \(theme) theme")
        }
        window.overrideUserInterfaceStyle = AppTheme.preferredColorScheme == .light ? .light : .dark
        let fixture = try CaptureFixture()
        self.fixture = fixture
        var shown = appeared.stream.makeAsyncIterator()
        var blank = cleared.stream.makeAsyncIterator()
        _ = await blank.next(isolation: #isolation)
        let thumbnails = try await withThrowingTaskGroup(of: (String, UIImage).self) { group in
            for next in screens {
                fixture.hostStore.selectHost(id: next == .switchHosts ? fixture.laptop.id : fixture.workstation.id)
                screen = next
                guard await shown.next(isolation: #isolation) == next else {
                    throw CaptureError("\(next.rawValue) did not appear")
                }
                try await settle(window, screen: next)
                let image = try await screenshot(next)
                let id = next.rawValue
                let directory = directory
                group.addTask { (id, try await CaptureFiles.write(image, named: id, into: directory)) }
                screen = nil
                _ = await blank.next(isolation: #isolation)
                try await settle(window, screen: next)
            }
            var thumbnails: [String: UIImage] = [:]
            for try await (id, thumbnail) in group {
                thumbnails[id] = thumbnail
            }
            return thumbnails
        }
        let ids = screens.map(\.rawValue)
        try writeSheet(ids.map { ($0, thumbnails[$0]!) })
        try JSONEncoder().encode(ids).write(to: directory.appending(path: "manifest.json"), options: .atomic)
    }

    private func keyWindow() async throws -> UIWindow {
        while true {
            let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            if let window = scene?.keyWindow {
                return window
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func settle(_ window: UIWindow, screen: CaptureScreen) async throws {
        var previous = try await drawnFrame(of: window, screen: screen)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(33))
            let next = try await drawnFrame(of: window, screen: screen)
            if next == previous { return }
            previous = next
        }
        throw CaptureError("\(screen.rawValue) did not settle")
    }

    private func drawnFrame(of window: UIWindow, screen: CaptureScreen) async throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.traitCollection.displayScale
        format.opaque = true
        for _ in 0..<30 {
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                complete = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            if complete, let data = image.cgImage?.dataProvider?.data as Data? { return data }
            try await Task.sleep(for: .milliseconds(33))
        }
        throw CaptureError("could not draw a complete frame for \(screen.rawValue)")
    }

    private func screenshot(_ screen: CaptureScreen) async throws -> UIImage {
        let file = directory.appending(path: "\(screen.rawValue).png")
        try Data(screen.rawValue.utf8).write(to: directory.appending(path: "ready"), options: .atomic)
        while true {
            if let image = UIImage(contentsOfFile: file.path()) { return image }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func writeSheet(_ thumbnails: [(id: String, image: UIImage)]) throws {
        let columns = min(thumbnails.count, 4)
        let rows = (thumbnails.count + columns - 1) / columns
        let pixels = thumbnails.map { CGSize(width: $0.image.size.width * $0.image.scale, height: $0.image.size.height * $0.image.scale) }
        let cell = CGSize(width: pixels.map(\.width).max()!, height: pixels.map(\.height).max()!)
        let gap: CGFloat = 32
        let label: CGFloat = 56
        let size = CGSize(width: gap + CGFloat(columns) * (cell.width + gap), height: gap + CGFloat(rows) * (cell.height + label + gap))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        let sheet = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { context in
            UIColor(white: 0.3, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, thumbnail) in thumbnails.enumerated() {
                let origin = CGPoint(x: gap + CGFloat(index % columns) * (cell.width + gap), y: gap + CGFloat(index / columns) * (cell.height + label + gap))
                thumbnail.image.draw(in: CGRect(origin: origin, size: pixels[index]))
                (thumbnail.id as NSString).draw(at: CGPoint(x: origin.x, y: origin.y + cell.height + 12), withAttributes: attributes)
            }
        }
        try sheet.write(to: directory.appending(path: "sheet.jpg"), options: .atomic)
    }
}

nonisolated private enum CaptureFiles {
    static let thumbnailHeight: CGFloat = 900

    @concurrent static func write(_ image: UIImage, named id: String, into directory: URL) async throws -> UIImage {
        let points = thumbnailHeight / image.scale
        guard let thumbnail = image.preparingThumbnail(of: CGSize(width: image.size.width * points / image.size.height, height: points)),
              let jpeg = thumbnail.jpegData(compressionQuality: 0.8) else {
            throw CaptureError("could not make the \(id) thumbnail")
        }
        try jpeg.write(to: directory.appending(path: "jpg/\(id).jpg"), options: .atomic)
        return thumbnail
    }
}

nonisolated private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
