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

    var tap: CaptureTap? {
        switch self {
        case .switchHosts: CaptureTap(label: "Host quick picker", type: "PopUpButton")
        case .themes where UIDevice.current.userInterfaceIdiom == .phone: CaptureTap(label: "Sheet Grabber", type: "Button")
        default: nil
        }
    }
}

nonisolated struct CaptureTap: Encodable {
    let label: String
    let type: String
}

nonisolated private struct CaptureReady: Encodable {
    let screen: String
    let tap: CaptureTap?
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
        if screen == .keyboardHidden {
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
            terminalFontSize: UIDevice.current.userInterfaceIdiom == .pad ? TerminalFontSizeSetting.maximumValue : TerminalFontSizeSetting.defaultValue,
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
        let session: ((Int, Int) -> TerminalPage)?
    }

    private static let suiteName = "dev.tuist.agentty.capture"
    private static let machines = [
        Machine(label: "workstation", address: "workstation.local", session: claudeCode),
        Machine(label: "laptop", address: "laptop.local", session: codex),
        Machine(label: "build-server", address: "192.0.2.24", session: nil),
    ]

    static var clockTime: Date? {
        CaptureView.directory == nil ? nil : Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now)
    }

    static var terminalIsDrawn = false
    static var redrawTerminal: (() -> Void)?

    static func terminalOutput(for host: AgenTTYHost?, columns: Int, rows: Int) -> String? {
        guard CaptureView.directory != nil,
              let session = machines.first(where: { $0.address == host?.address })?.session else {
            return nil
        }
        terminalIsDrawn = false
        return session(columns, rows).output(rows: rows) + TerminalPage.csi + "18t"
    }

    static func terminalDrewOutput(reporting reply: Data, columns: Int, rows: Int) -> Bool? {
        guard CaptureView.directory != nil,
              let match = String(decoding: reply, as: UTF8.self).wholeMatch(of: /\u{1B}\[8;(\d+);(\d+)t/) else {
            return nil
        }
        terminalIsDrawn = Int(match.1) == rows && Int(match.2) == columns
        return terminalIsDrawn
    }

    nonisolated private static func claudeCode(columns: Int, rows: Int) -> TerminalPage {
        let orange = TerminalPage.csi + "38;2;215;119;87m"
        let gray = TerminalPage.csi + "90m"
        let green = TerminalPage.csi + "32m"
        let red = TerminalPage.csi + "31m"
        let reset = TerminalPage.csi + "0m"
        var header = TerminalPage(columns: columns)
        header.add(" \(orange)▐▛███▜▌\(reset)   \(TerminalPage.csi)1mClaude Code\(reset) v2.1.92")
        header.add("\(orange)▝▜█████▛▘\(reset)  \(gray)Opus 4.6 · Claude Max\(reset)")
        header.add("  \(orange)▘▘ ▝▝\(reset)    \(gray)~/projects/agentty\(reset)")
        header.add()

        func prompt(_ text: String) -> TerminalPage {
            var page = TerminalPage(columns: columns)
            page.add(TerminalPage.csi + "100m" + "> \(text)".padding(toLength: columns, withPad: " ", startingAt: 0) + reset)
            page.add()
            return page
        }
        func tool(_ call: String, _ result: [String]) -> TerminalPage {
            var page = TerminalPage(columns: columns)
            page.add("\(green)⏺\(reset) \(TerminalPage.csi)1m\(call)\(reset)")
            for (index, line) in result.enumerated() {
                page.add((index == 0 ? "  \(gray)⎿\(reset)  " : "     ") + line)
            }
            page.add()
            return page
        }
        func reply(_ text: String) -> TerminalPage {
            var page = TerminalPage(columns: columns)
            page.wrap(text, marker: "⏺ ", indent: 2)
            page.add()
            return page
        }

        let earlier = [
            prompt("add a retry with backoff to the webhook sender")
                + tool("Read(src/webhooks/send.ts)", ["Read 88 lines"])
                + tool("Update(src/webhooks/send.ts)", [
                    "Updated src/webhooks/send.ts with 7 additions and 1 removal",
                    "  \(gray)31\(reset) \(red)-    await post(url, body)\(reset)",
                    "  \(gray)31\(reset) \(green)+    for (let attempt = 1; ; attempt++) {\(reset)",
                    "  \(gray)32\(reset) \(green)+      try {\(reset)",
                    "  \(gray)33\(reset) \(green)+        return await post(url, body)\(reset)",
                    "  \(gray)34\(reset) \(green)+      } catch (error) {\(reset)",
                    "  \(gray)35\(reset) \(green)+        if (attempt === 5 || !isRetryable(error)) throw error\(reset)",
                    "  \(gray)36\(reset) \(green)+        await sleep(2 ** attempt * 250 + Math.random() * 250)\(reset)",
                    "  \(gray)37\(reset) \(green)+      }\(reset)",
                ])
                + reply("Webhook sends now retry transient failures up to five times with jittered exponential backoff."),
            prompt("the relay drops idle sessions after 30 seconds, find out why")
                + tool("Search(pattern: \"idle_timeout\", path: \"services/relay\")", ["Found 3 files"])
                + tool("Read(services/relay/src/session.rs)", ["Read 214 lines"])
                + reply("The relay closes sessions after 30 idle seconds, but clients send a keepalive only every 45. I lowered the client interval to 15 seconds, and the idle-session test passes."),
            prompt("pull main and run the tests")
                + tool("Bash(git pull --ff-only && just test)", [
                    "Updating 8b31d07..c4e2a91",
                    "6 files changed, 142 insertions(+), 37 deletions(-)",
                    "\(green)✔\(reset) 312 tests passed (41.2s)",
                ])
                + reply("main is up to date and all 312 tests pass."),
        ]

        var answer = prompt("why do I need this app?")
        answer.wrap("AgenTTY turns your iPhone into a real terminal for the agents on your own machines: a GPU-rendered, Ghostty-powered SSH client that feels native to iOS.", marker: "⏺ ", indent: 2)
        answer.add()
        for (title, text) in [
            ("Instant reconnect", "tmux sessions persist across disconnects, so you pick up exactly where you left off"),
            ("Full terminal rendering", "Metal-backed Ghostty engine with proper fonts, themes and smooth scrolling"),
            ("Push notifications from your server", "get pinged when a build finishes, a deploy completes or Claude Code needs your attention"),
            ("Zero-config pairing", "scan a QR code; SSH keys are generated and installed automatically"),
            ("Custom touch keyboard", "modifier chords, slide gestures and dictation, built for terminal work"),
            ("Shell quick switcher", "long-press the space bar to flip between tmux sessions like switching apps"),
        ] {
            answer.wrap("\(title) – \(text)", marker: "  - ", indent: 4, bold: title.count)
        }
        answer.add()
        answer.wrap("Your agents keep working on your machine; your phone is the window into them, wherever you are.", marker: "  ", indent: 2)
        answer.add()

        var input = TerminalPage(columns: columns)
        input.rule()
        input.add("> ")
        input.markCursor(column: 3)
        input.rule()
        input.add("  \(orange)Opus 4.6\(reset) \(gray)· 12% context ·\(reset) \(TerminalPage.csi)36magentty\(reset) \(green)main\(reset)")
        input.add("  \(TerminalPage.csi)38;2;255;107;128m⏵⏵ bypass permissions on\(reset)\(gray) (shift+tab to cycle)\(reset)")

        var session = answer + input
        for exchange in earlier.reversed() where header.lineCount + exchange.lineCount + session.lineCount <= rows {
            session = exchange + session
        }
        return header + session
    }

    nonisolated private static func codex(columns: Int, rows: Int) -> TerminalPage {
        let cyan = TerminalPage.csi + "36m"
        let green = TerminalPage.csi + "32m"
        let red = TerminalPage.csi + "31m"
        let gray = TerminalPage.csi + "90m"
        let bold = TerminalPage.csi + "1m"
        let reset = TerminalPage.csi + "0m"
        let box = min(columns - 1, 48) - 2
        var page = TerminalPage(columns: columns)
        page.add("╭" + String(repeating: "─", count: box) + "╮")
        for row in [">_ \(bold)OpenAI Codex\(reset) \(gray)(v0.80.0)\(reset)", "", "\(gray)model:\(reset)     gpt-5.5 high", "\(gray)directory:\(reset) ~/projects/site"] {
            let visible = row.replacing(/\u{1B}\[[0-9;]*m/, with: "").count
            page.add("│ " + row + String(repeating: " ", count: max(0, box - 2 - visible)) + " │")
        }
        page.add("╰" + String(repeating: "─", count: box) + "╯")
        page.add()
        page.wrap("The checkout test fails about one run in ten. Find out why and fix it.", marker: "\(cyan)›\(reset) ", indent: 2)
        page.add()
        page.add("\(bold)•\(reset) \(bold)Explored\(reset)")
        page.add("  \(gray)└\(reset) Read checkout.test.ts, total.ts")
        page.add("    Search round\\( in src/cart")
        page.add()
        page.add("\(bold)•\(reset) \(bold)Ran\(reset) bun test checkout --rerun-each 20")
        page.add("  \(gray)└\(reset) \(red)2 of 20 runs failed:\(reset) expected 41.97, received 41.96")
        page.add()
        page.wrap("Each line total is rounded, then the order total is rounded again, so carts whose lines end in half a cent lose one. I’ll round once, at the end.", marker: "\(bold)•\(reset) ", indent: 2)
        page.add()
        page.add("\(bold)•\(reset) \(bold)Edited\(reset) src/cart/total.ts \(green)(+2\(reset) \(red)-2)\(reset)")
        page.add("    \(gray)12\(reset) \(red)-  const lines = items.map(i => round(i.price * i.qty))\(reset)")
        page.add("    \(gray)12\(reset) \(green)+  const lines = items.map(i => i.price * i.qty)\(reset)")
        page.add("    \(gray)18\(reset) \(red)-  return round(sum(lines)) - discount\(reset)")
        page.add("    \(gray)18\(reset) \(green)+  return round(sum(lines) - discount)\(reset)")
        page.add()
        page.add("\(bold)•\(reset) \(bold)Ran\(reset) bun test checkout --rerun-each 50")
        page.add("  \(gray)└\(reset) \(green)50 of 50 runs passed\(reset)")
        page.add()
        page.add(gray + "─ Worked for 1m 12s " + String(repeating: "─", count: max(0, columns - 21)) + reset)
        page.add()
        page.wrap("The flaky test came from rounding twice in cartTotal. Totals are now rounded once, and 50 repeated runs pass.", marker: "\(bold)•\(reset) ", indent: 2)
        page.add()
        page.add("\(cyan)›\(reset) ")
        page.markCursor(column: 3)
        page.add()
        page.add("  \(gray)⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit\(reset)")
        return page
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

nonisolated private struct TerminalPage {
    static let csi = "\u{1B}["

    let columns: Int
    private var lines: [String] = []
    private var cursor: (line: Int, column: Int)?

    init(columns: Int) {
        self.columns = columns
    }

    mutating func add(_ line: String = "") {
        lines.append(line)
    }

    mutating func rule() {
        add(Self.csi + "90m" + String(repeating: "─", count: columns) + Self.csi + "0m")
    }

    mutating func wrap(_ text: String, marker: String, indent: Int, bold: Int = 0) {
        let width = max(columns - indent - 1, 16)
        var rows: [String] = []
        for word in text.split(separator: " ") {
            if let last = rows.last, last.count + 1 + word.count <= width {
                rows[rows.count - 1] = last + " " + word
            } else {
                rows.append(String(word))
            }
        }
        for (index, row) in rows.enumerated() {
            let body = index == 0 && bold > 0 ? Self.csi + "1m" + row.prefix(bold) + Self.csi + "22m" + row.dropFirst(bold) : row
            add((index == 0 ? marker : String(repeating: " ", count: indent)) + body)
        }
    }

    mutating func markCursor(column: Int) {
        cursor = (lines.count - 1, column)
    }

    var lineCount: Int {
        lines.count
    }

    static func + (top: TerminalPage, bottom: TerminalPage) -> TerminalPage {
        var page = top
        page.lines += bottom.lines
        if let cursor = bottom.cursor {
            page.cursor = (top.lines.count + cursor.line, cursor.column)
        }
        return page
    }

    func output(rows: Int) -> String {
        var output = "\u{1B}c" + Self.csi + "2 q" + lines.joined(separator: "\r\n")
        if let cursor {
            output += Self.csi + "\(cursor.line - max(0, lines.count - rows) + 1);\(cursor.column)H"
        }
        return output
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
                CaptureFixture.terminalIsDrawn = false
                screen = next
                guard await shown.next(isolation: #isolation) == next else {
                    throw CaptureError("\(next.rawValue) did not appear")
                }
                try await terminalDrawn(next)
                try await settle(window, screen: next)
                CaptureFixture.terminalIsDrawn = false
                CaptureFixture.redrawTerminal?()
                try await terminalDrawn(next)
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

    private func terminalDrawn(_ screen: CaptureScreen) async throws {
        for _ in 0..<500 {
            if CaptureFixture.terminalIsDrawn { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CaptureError("the \(screen.rawValue) terminal never drew its session in its final grid")
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
        try JSONEncoder().encode(CaptureReady(screen: screen.rawValue, tap: screen.tap)).write(to: directory.appending(path: "ready"), options: .atomic)
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
