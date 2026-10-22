import SwiftUI
import UIKit

@safe
struct SSHPublicKeyExportView: View {
    let publicKey: String

    @State private var hasCopied = false
    @State private var copyFeedbackToken = 0
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: publicKey)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            Rectangle()
                .fill(AppTheme.surfaceOrnamentStroke)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                Button {
                    performCopy()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(hasCopied ? .green : AppTheme.secondaryText)
                            .contentTransition(.symbolEffect(.replace))
                        Text(hasCopied ? "Copied" : "Copy")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(hasCopied ? .green : AppTheme.primaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasCopied ? "Copied public key" : "Copy public key")

                Rectangle()
                    .fill(AppTheme.surfaceOrnamentStroke)
                    .frame(width: 0.5, height: 20)

                ShareLink(item: publicKey) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        Text("Share")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share public key")
            }
            .padding(.vertical, 4)
        }
        .animation(.easeOut(duration: 0.2), value: hasCopied)
        .padding(.vertical, 0)
        .listRowInsets(EdgeInsets(top: 13, leading: 16, bottom: 9, trailing: 16))
        .listRowBackground(AppTheme.sheetListRowBackground)
        .sensoryFeedback(.selection, trigger: copyFeedbackToken)
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func performCopy() {
        UIPasteboard.general.string = publicKey
        copyFeedbackToken &+= 1

        copyResetTask?.cancel()
        withAnimation(.spring(duration: 0.22, bounce: 0.22)) {
            hasCopied = true
        }

        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    hasCopied = false
                }
                copyResetTask = nil
            }
        }
    }
}
