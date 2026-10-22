import SwiftUI

@safe
struct TerminalTipsSheet: View {
    private let sections = TerminalTipsSection.all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Shortcuts, gestures, and hidden conveniences that make AgenTTY feel much faster once you know them.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 4)
                }
                .listRowBackground(AppTheme.sheetListRowBackground)

                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.tips) { tip in
                            TerminalTipRow(tip: tip)
                        }
                        .listRowBackground(AppTheme.sheetListRowBackground)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .containerBackground(.clear, for: .navigation)
            .navigationTitle("Tips & Tricks")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TerminalTipsSection: Identifiable {
    let title: String
    let tips: [TerminalTip]

    var id: String { title }

    static let all: [TerminalTipsSection] = [
        TerminalTipsSection(
            title: "Move Around",
            tips: [
                TerminalTip(
                    icon: "arrow.left.arrow.right.circle.fill",
                    iconTint: .indigo,
                    title: "Swipe the terminal to switch shells",
                    detail: "Swipe left or right directly on the terminal surface to move between shells. Swiping forward from the last shell creates a new one.",
                    badge: "Swipe"
                ),
                TerminalTip(
                    icon: "space",
                    iconTint: .blue,
                    title: "Hold the spacebar for the quick switcher",
                    detail: "Long-press the spacebar to open shell cards, then slide and release to jump. Release on the trailing plus card to create a new shell immediately.",
                    badge: "Hold"
                ),
                TerminalTip(
                    icon: "server.rack",
                    iconTint: .mint,
                    title: "Swipe the host capsule to switch hosts",
                    detail: "Swipe left or right on the host control in the top status bar to jump between saved hosts without opening the Hosts sheet.",
                    badge: "Swipe"
                ),
                TerminalTip(
                    icon: "capsule.lefthalf.filled",
                    iconTint: .teal,
                    title: "Read the bottom shell strip",
                    detail: "The left chip shows the active folder and the right chip shows the current Git branch, so you can tell where the shell is before you type.",
                    badge: "UI"
                ),
            ]
        ),
        TerminalTipsSection(
            title: "Keyboard Tricks",
            tips: [
                TerminalTip(
                    icon: "document.on.clipboard.fill",
                    iconTint: .purple,
                    title: "Paste with Ctrl+V",
                    detail: "In Default (Shortcuts) keyboard mode, Ctrl+V pastes clipboard text into tools like Claude and Codex. If the clipboard holds copied images or files, AgenTTY uploads them first and pastes their remote paths.",
                    badge: "Ctrl+V"
                ),
                TerminalTip(
                    icon: "command.circle",
                    iconTint: .pink,
                    title: "Lock modifiers and send chords quickly",
                    detail: "Hold Shift, Ctrl, or Alt and slide up to lock it. While holding a modifier, drag onto another key and release to send the chord in one motion.",
                    badge: "Drag"
                ),
                TerminalTip(
                    icon: "xmark.circle.fill",
                    iconTint: .red,
                    title: "Close the current shell with Ctrl+D",
                    detail: "Ctrl+D sends EOF to the active program or shell. When the current shell exits, tmux closes that shell window for you.",
                    badge: "Ctrl+D"
                ),
            ]
        ),
        TerminalTipsSection(
            title: "Touch & Text",
            tips: [
                TerminalTip(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    iconTint: .orange,
                    title: "Drag vertically to scroll",
                    detail: "Use a one-finger vertical drag directly on the terminal to scroll output. Horizontal swipes are reserved for shell switching.",
                    badge: "Scroll"
                ),
                TerminalTip(
                    icon: "text.cursor",
                    iconTint: .green,
                    title: "Long-press for text actions",
                    detail: "Long-press in the terminal to open the edit menu. If text is selected you can copy it, and when the clipboard has content you can paste directly from the same menu.",
                    badge: "Paste"
                ),
                TerminalTip(
                    icon: "link",
                    iconTint: .yellow,
                    title: "Tap links directly",
                    detail: "A single tap opens links. AgenTTY also adapts its click behavior for full-screen terminal apps that use mouse capture.",
                    badge: "Tap"
                ),
            ]
        ),
    ]
}

private struct TerminalTip: Identifiable {
    let icon: String
    let iconTint: Color
    let title: String
    let detail: String
    let badge: String

    var id: String { title }
}

@safe
private struct TerminalTipRow: View {
    let tip: TerminalTip

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tip.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.darkModePrimaryText)
                .frame(width: 28, height: 28)
                .background(tip.iconTint.gradient, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(tip.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    Text(tip.badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.surfaceOrnamentFill, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 1)
                        )
                }

                Text(tip.detail)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}
