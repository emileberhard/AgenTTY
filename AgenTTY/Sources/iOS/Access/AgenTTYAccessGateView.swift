import SwiftUI

@safe
struct AgenTTYAccessGateView: View {
    @Environment(AgenTTYLifetimeAccessController.self) private var accessController
    let analyticsClient: AgenTTYAnalyticsClient

    private static let usageFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private let cardCornerRadius: CGFloat = 28
    private let topSafeAreaPadding: CGFloat = 20
    private let bottomSafeAreaPadding: CGFloat = 50
    private let contentVerticalPadding: CGFloat = 40
    private let heroToCardSpacing: CGFloat = 10
    private let heroContentLift: CGFloat = 20
    private let minimumHeroRegionHeight: CGFloat = 150
    private let maximumHeroRegionHeight: CGFloat = 190

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppTheme.terminalBackgroundBright.opacity(0.95),
                    AppTheme.terminalBackground.opacity(0.95),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Rectangle()
                .fill(.black.opacity(0.32))
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: heroToCardSpacing) {
                        heroRegion
                            .frame(maxWidth: .infinity)
                            .frame(height: heroRegionHeight(in: geometry))

                        contentCard
                            .frame(maxWidth: 560)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, contentVerticalPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaPadding(.top, topSafeAreaPadding)
                .safeAreaPadding(.bottom, bottomSafeAreaPadding)
            }
        }
        .allowsHitTesting(true)
        .task {
            await analyticsClient.recordPaywall(
                AgenTTYAnalyticsPaywallEvent(
                    stage: .shown,
                    accessState: accessController.analyticsAccessState
                )
            )
        }
    }

    private var heroRegion: some View {
        VStack {
            Spacer(minLength: 0)
            badge
                .offset(y: -heroContentLift)
            Spacer(minLength: 0)
        }
    }

    private func heroRegionHeight(in geometry: GeometryProxy) -> CGFloat {
        min(
            max(
                geometry.size.height * 0.18,
                minimumHeroRegionHeight
            ),
            maximumHeroRegionHeight
        )
    }

    private var badge: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(AppTheme.darkModePrimaryText)
                .frame(width: 58, height: 58)
                .background(AppTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("AgenTTY")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.primaryText)

            Text("SSH from your iPhone, with one permanent unlock.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            expiredTrialContent
        }
        .padding(24)
        .background(AppTheme.surfaceOrnamentFill, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .glassEffect(AppTheme.glass(.regular), in: .rect(cornerRadius: cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(AppTheme.surfaceOrnamentStroke, lineWidth: 1)
        )
    }

    private var expiredTrialContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your free usage has ended")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .allowsTightening(true)

                Text("Unlock AgenTTY with a one-time in-app purchase after \(formattedUsage(AgenTTYTrialPolicy.usageLimit)) of free usage. This is not a subscription.")
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            if let trialStatus = accessController.trialStatus {
                VStack(alignment: .leading, spacing: 10) {
                    infoRow(
                        icon: "calendar",
                        title: "Trial started",
                        value: trialStatus.startedAt.formatted(date: .abbreviated, time: .omitted)
                    )
                    infoRow(
                        icon: "timer",
                        title: "Free usage included",
                        value: formattedUsage(trialStatus.usageLimit)
                    )
                    infoRow(
                        icon: "clock.badge.xmark",
                        title: "Free usage used",
                        value: formattedUsage(trialStatus.consumedUsage)
                    )
                    if let priceLabel = accessController.productPriceLabel {
                        infoRow(
                            icon: "dollarsign.circle",
                            title: "Lifetime access",
                            value: "\(priceLabel) one-time"
                        )
                    }
                }
            }

            VStack(spacing: 12) {
                Button {
                    Task {
                        recordPaywallEvent(.purchaseTapped)
                        await accessController.purchaseLifetimeAccess()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if case .purchasing = accessController.flowState {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "lock.open.display")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text(accessController.purchaseButtonLabel)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(AppTheme.accent)
                .disabled(accessController.isWorking)

                Button {
                    Task {
                        recordPaywallEvent(.restoreTapped)
                        await accessController.restorePurchases()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if case .restoring = accessController.flowState {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        Text("Restore Purchase")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .disabled(accessController.isWorking)

                Button("Retry App Store Lookup") {
                    Task {
                        recordPaywallEvent(.retryLookupTapped)
                        await accessController.retryFromPaywall()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .disabled(accessController.isWorking)
            }

            if let statusMessage = accessController.statusMessage {
                Text(statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("If you already bought lifetime access, restore uses your Apple Account and unlocks automatically.")
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)

                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func recordPaywallEvent(_ stage: AgenTTYAnalyticsPaywallStage) {
        let accessState = accessController.analyticsAccessState
        Task {
            await analyticsClient.recordPaywall(
                AgenTTYAnalyticsPaywallEvent(stage: stage, accessState: accessState)
            )
        }
    }

    private func formattedUsage(_ interval: TimeInterval) -> String {
        let sanitizedInterval = max(0, interval.rounded(.down))
        return Self.usageFormatter.string(from: sanitizedInterval) ?? "0 minutes"
    }
}

#if DEBUG
#Preview("Expired Trial Paywall") {
    AgenTTYAccessGateView(analyticsClient: AgenTTYAnalyticsClient(flavor: .main))
        .environment(AgenTTYLifetimeAccessController.previewExpiredTrial())
        .preferredColorScheme(.dark)
}
#endif
