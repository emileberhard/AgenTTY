import SwiftUI
import UIKit

@safe
struct HostSetupMethodPickerView: View {
    let onSelectRoute: (HostsRoute) -> Void

    var body: some View {
        List {
            Section {
                setupMethodButton(for: .manual, route: .addManual)
                setupMethodButton(for: .pairWithCommand, route: .addAutomatic)
                setupMethodButton(for: .oneTimePassword, route: .addOneTimePassword)
            } header: {
                Text("Setup Method")
            } footer: {
                Text("Choose how you want to add this host. Automatic Setup is the fastest path for a new machine. Password Setup signs in with your SSH password once and switches to key auth.")
            }
        }
        .listSectionSpacing(24)
        .scrollContentBackground(.hidden)
        .containerBackground(.clear, for: .navigation)
        .navigationTitle("New Host")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setupMethodButton(
        for method: HostSetupMethod,
        route: HostsRoute
    ) -> some View {
        Button {
            onSelectRoute(route)
        } label: {
            HostSetupMethodCard(method: method, isSelected: false)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

@safe
struct HostInfoRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var selectableSubtitle = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(AppTheme.primaryText)
                subtitleView
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    @ViewBuilder
    private var subtitleView: some View {
        if selectableSubtitle {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .textSelection(.enabled)
        } else {
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }
}

@safe
struct HostCommandRow: View {
    let icon: String
    let title: String
    let command: String

    @State private var hasCopied = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .foregroundStyle(AppTheme.primaryText)

                Button {
                    UIPasteboard.general.string = command
                    withAnimation(.spring(duration: 0.2)) {
                        hasCopied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            hasCopied = false
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer(minLength: 0)

                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(hasCopied ? .green : AppTheme.secondaryText)
                            .frame(width: 20, height: 20)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(commandBackground)
                    .overlay(commandBorder)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasCopied ? "Copied" : "Copy command")
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .listRowBackground(AppTheme.sheetListRowBackground)
    }

    private var commandBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(AppTheme.surfaceOrnamentFill)
    }

    private var commandBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(
                hasCopied ? Color.green.opacity(0.4) : AppTheme.surfaceOrnamentStroke,
                lineWidth: 1
            )
    }
}

@safe
struct HostCardRow: View {
    let host: AgenTTYHost
    let keyName: String?
    let isActive: Bool
    let reachabilityState: HostListReachabilityIndicatorState

    private var authSummary: String? {
        switch host.authentication {
        case .key:
            return keyName
        case .passwordBootstrap:
            return "one-time password setup pending"
        }
    }

    private var hostAccentColor: Color {
        isActive ? .green : .teal
    }

    private var endpointSummary: String {
        guard AgenTTYSSHSeedPolicy.isScreenshotMode else {
            return "\(host.username)@\(host.address):\(host.port)"
        }
        return "developer@\(host.label).local:\(host.port)"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.darkModePrimaryText)
                .frame(width: 32, height: 32)
                .background(hostAccentColor.gradient, in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    Text(host.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)

                    HostReachabilityPill(state: reachabilityState)
                        .fixedSize()
                        .padding(.leading, 1)

                    Spacer(minLength: 8)
                }
                .padding(.bottom, 2)

                Text(endpointSummary)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let authSummary {
                    Text(authSummary)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.secondaryText.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText.opacity(0.8))
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}

@safe
private struct HostReachabilityPill: View {
    let state: HostListReachabilityIndicatorState

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: state.symbolName)
                .font(.system(size: 8.5, weight: .semibold))

            Text(state.displayText)
                .font(.system(size: 8.5, weight: .semibold, design: .default))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(backgroundFill, in: Capsule())
        .overlay(
            Capsule()
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var backgroundFill: Color {
        state.tint.opacity(0.14)
    }

    private var borderColor: Color {
        state.tint.opacity(0.3)
    }
}

@safe
private struct HostSetupMethodCard: View {
    let method: HostSetupMethod
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: method.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? AppTheme.darkModePrimaryText : method.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    method.accentColor.opacity(isSelected ? 0.85 : 0.14),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(method.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)

                Text(method.subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? method.accentColor : AppTheme.secondaryText.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(.rect)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(isSelected ? method.accentColor.opacity(0.10) : AppTheme.sheetListRowBackground)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                isSelected ? method.accentColor.opacity(0.45) : AppTheme.surfaceOrnamentStroke,
                lineWidth: 1
            )
    }
}
