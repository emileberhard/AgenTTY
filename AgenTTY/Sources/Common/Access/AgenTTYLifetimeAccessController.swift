import Foundation
import Observation
import StoreKit
@unsafe @preconcurrency import Security

nonisolated struct AgenTTYUsageTrialRecord: Codable, Equatable, Sendable {
    var startedAt: Date
    var consumedUsage: TimeInterval
}

nonisolated struct AgenTTYTrialStatus: Equatable, Sendable {
    let startedAt: Date
    let usageLimit: TimeInterval
    let consumedUsage: TimeInterval

    var isExpired: Bool {
        consumedUsage >= usageLimit
    }

    var remainingUsage: TimeInterval {
        max(0, usageLimit - consumedUsage)
    }
}

private struct AgenTTYUsageTrialSessionStart {
    let wallClockStartedAt: Date
    let systemUptimeStartedAt: TimeInterval
}

nonisolated enum AgenTTYLifetimeAccessProduct {
    static let productID = AgenTTYBuildConfiguration.unlockProductID
    static let fallbackDisplayName = "Lifetime Access"
}

nonisolated enum AgenTTYLocalMainInstallUnlockPolicy {
    static var isEnabled: Bool {
#if AGENTTY_LOCAL_MAIN_UNLOCK
        true
#else
        false
#endif
    }
}

nonisolated enum AgenTTYTrialPolicy {
    static let usageLimit: TimeInterval = 5 * 60 * 60

    static func mergeRecord(
        keychainRecord: AgenTTYUsageTrialRecord?,
        mirroredRecord: AgenTTYUsageTrialRecord?,
        now: Date
    ) -> AgenTTYUsageTrialRecord {
        let storedRecords = [keychainRecord, mirroredRecord].compactMap { $0 }
        return AgenTTYUsageTrialRecord(
            startedAt: min(now, storedRecords.map(\.startedAt).min() ?? now),
            consumedUsage: min(
                usageLimit,
                max(0, storedRecords.map(\.consumedUsage).max() ?? 0)
            )
        )
    }

    static func status(for record: AgenTTYUsageTrialRecord) -> AgenTTYTrialStatus {
        AgenTTYTrialStatus(
            startedAt: record.startedAt,
            usageLimit: usageLimit,
            consumedUsage: min(usageLimit, max(0, record.consumedUsage))
        )
    }

    static func updatedRecord(
        from record: AgenTTYUsageTrialRecord,
        adding elapsedUsage: TimeInterval
    ) -> AgenTTYUsageTrialRecord {
        AgenTTYUsageTrialRecord(
            startedAt: record.startedAt,
            consumedUsage: min(usageLimit, max(0, record.consumedUsage + max(0, elapsedUsage)))
        )
    }

    static func measuredElapsedUsage(
        wallClockStartedAt: Date,
        systemUptimeStartedAt: TimeInterval,
        now: Date,
        systemUptime: TimeInterval
    ) -> TimeInterval {
        if systemUptime >= systemUptimeStartedAt {
            return max(0, systemUptime - systemUptimeStartedAt)
        }

        return max(0, now.timeIntervalSince(wallClockStartedAt))
    }
}

nonisolated enum AgenTTYLifetimeEntitlementLookup: Equatable, Sendable {
    case active
    case revoked
    case absent
    case inconclusive
}

nonisolated enum AgenTTYLifetimeAccessPolicy {
    static func shouldRenderInteractiveContent(
        enforcesPaywall: Bool,
        hasFinishedInitialAccessLoad: Bool,
        hasLifetimeAccess: Bool,
        trialStatus: AgenTTYTrialStatus?
    ) -> Bool {
        guard enforcesPaywall else { return true }
        guard hasFinishedInitialAccessLoad else { return true }
        if hasLifetimeAccess {
            return true
        }
        guard let trialStatus else {
            return false
        }
        return !trialStatus.isExpired
    }

    static func shouldBlockWithGate(
        enforcesPaywall: Bool,
        hasFinishedInitialAccessLoad: Bool,
        hasLifetimeAccess: Bool,
        trialStatus: AgenTTYTrialStatus?
    ) -> Bool {
        guard enforcesPaywall else { return false }
        guard hasFinishedInitialAccessLoad else { return false }
        guard !hasLifetimeAccess else { return false }
        guard let trialStatus else { return false }
        return trialStatus.isExpired
    }

    static func reconciledLifetimeAccess(
        currentValue: Bool,
        lookup: AgenTTYLifetimeEntitlementLookup
    ) -> Bool {
        switch lookup {
        case .active:
            true
        case .revoked:
            false
        case .absent, .inconclusive:
            currentValue
        }
    }
}

nonisolated final class AgenTTYTrialRecordStore: @unchecked Sendable {
    private static let mirroredDefaultsKey = "lifetime-access.usage-trial.v2"
    private static let keychainService = "\(AgenTTYBuildConfiguration.keychainNamespace).lifetime-access-usage-trial.v2"
    private static let keychainAccount = "current-device"

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = AgenTTYSharedDefaults.store) {
        self.userDefaults = userDefaults
    }

    func loadCurrentRecord(now: Date) -> AgenTTYUsageTrialRecord {
        let keychainRecord = loadKeychainRecord()
        let mirroredRecord = loadMirroredRecord()
        let mergedRecord = AgenTTYTrialPolicy.mergeRecord(
            keychainRecord: keychainRecord,
            mirroredRecord: mirroredRecord,
            now: now
        )
        if keychainRecord != mergedRecord || mirroredRecord != mergedRecord {
            persist(mergedRecord)
        }
        return mergedRecord
    }

    func persist(_ record: AgenTTYUsageTrialRecord) {
        persistMirroredRecord(record)
        persistKeychainRecord(record)
    }

    private func loadMirroredRecord() -> AgenTTYUsageTrialRecord? {
        guard let data = userDefaults.data(forKey: Self.mirroredDefaultsKey) else {
            return nil
        }
        return try? decoder.decode(AgenTTYUsageTrialRecord.self, from: data)
    }

    private func persistMirroredRecord(_ record: AgenTTYUsageTrialRecord) {
        guard let data = try? encoder.encode(record) else {
            return
        }
        userDefaults.set(data, forKey: Self.mirroredDefaultsKey)
    }

    private func loadKeychainRecord() -> AgenTTYUsageTrialRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess else {
            EsmaLog.app.error(
                "event=lifetime_access_trial_keychain_read_failed status=\(status, privacy: .public)"
            )
            return nil
        }
        guard let data = result as? Data else {
            return nil
        }
        return try? decoder.decode(AgenTTYUsageTrialRecord.self, from: data)
    }

    private func persistKeychainRecord(_ record: AgenTTYUsageTrialRecord) {
        guard let payload = try? encoder.encode(record) else {
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            EsmaLog.app.error(
                "event=lifetime_access_trial_keychain_update_failed status=\(updateStatus, privacy: .public)"
            )
            return
        }

        var addQuery = query
        addQuery[kSecValueData as String] = payload
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            EsmaLog.app.error(
                "event=lifetime_access_trial_keychain_add_failed status=\(addStatus, privacy: .public)"
            )
        }
    }
}

@MainActor
@Observable
final class AgenTTYLifetimeAccessController {
    enum FlowState: Equatable {
        case idle
        case purchasing
        case restoring
        case pending
        case failed(String)
    }

    private(set) var hasFinishedInitialAccessLoad = false
    private(set) var hasLifetimeAccess = false
    private(set) var trialStatus: AgenTTYTrialStatus?
    private(set) var lifetimeProduct: Product?
    private(set) var flowState: FlowState = .idle
    private(set) var productLoadErrorMessage: String?

    private static let initialEntitlementGracePeriod: Duration = .seconds(5)

    @ObservationIgnored
    private let flavor: AgenTTYBuildFlavor
    @ObservationIgnored
    private let trialRecordStore: AgenTTYTrialRecordStore
    @ObservationIgnored
    private let analyticsClient: AgenTTYAnalyticsClient?
    @ObservationIgnored
    private let previewDisplayPrice: String?
    @ObservationIgnored
    private let localMainInstallUnlockEnabled: Bool
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var usageCheckpointTask: Task<Void, Never>?
    @ObservationIgnored
    private var currentTrialRecord: AgenTTYUsageTrialRecord?
    @ObservationIgnored
    private var activeUsageSessionStart: AgenTTYUsageTrialSessionStart?
    @ObservationIgnored
    private var isSceneActive = false

    init(
        flavor: AgenTTYBuildFlavor = .current(),
        trialRecordStore: AgenTTYTrialRecordStore = AgenTTYTrialRecordStore(),
        analyticsClient: AgenTTYAnalyticsClient? = nil,
        localMainInstallUnlockEnabled: Bool = AgenTTYLocalMainInstallUnlockPolicy.isEnabled
    ) {
        self.flavor = flavor
        self.trialRecordStore = trialRecordStore
        self.analyticsClient = analyticsClient
        previewDisplayPrice = nil
        self.localMainInstallUnlockEnabled = flavor == .main && localMainInstallUnlockEnabled

        guard enforcesLifetimeAccessPaywall else {
            hasFinishedInitialAccessLoad = true
            hasLifetimeAccess = true
            return
        }

        startTransactionListener()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await self.performInitialLoad()
        }
    }

    private init(
        previewDisplayPrice: String? = nil,
        previewHasLifetimeAccess: Bool,
        previewTrialStatus: AgenTTYTrialStatus?
    ) {
        flavor = .main
        trialRecordStore = AgenTTYTrialRecordStore()
        analyticsClient = nil
        self.previewDisplayPrice = previewDisplayPrice
        localMainInstallUnlockEnabled = false

        hasFinishedInitialAccessLoad = true
        hasLifetimeAccess = previewHasLifetimeAccess
        lifetimeProduct = nil
        flowState = .idle
        productLoadErrorMessage = nil
        trialStatus = previewTrialStatus
        currentTrialRecord = previewTrialStatus.map {
            AgenTTYUsageTrialRecord(startedAt: $0.startedAt, consumedUsage: $0.consumedUsage)
        }
    }

    deinit {
        startupTask?.cancel()
        updatesTask?.cancel()
        usageCheckpointTask?.cancel()
    }

    private var enforcesLifetimeAccessPaywall: Bool {
        flavor.enforcesLifetimeAccessPaywall && !localMainInstallUnlockEnabled
    }

    var shouldRenderInteractiveContent: Bool {
        AgenTTYLifetimeAccessPolicy.shouldRenderInteractiveContent(
            enforcesPaywall: enforcesLifetimeAccessPaywall,
            hasFinishedInitialAccessLoad: hasFinishedInitialAccessLoad,
            hasLifetimeAccess: hasLifetimeAccess,
            trialStatus: trialStatus
        )
    }

    var shouldBlockWithGate: Bool {
        AgenTTYLifetimeAccessPolicy.shouldBlockWithGate(
            enforcesPaywall: enforcesLifetimeAccessPaywall,
            hasFinishedInitialAccessLoad: hasFinishedInitialAccessLoad,
            hasLifetimeAccess: hasLifetimeAccess,
            trialStatus: trialStatus
        )
    }

    var isWorking: Bool {
        switch flowState {
        case .purchasing, .restoring:
            true
        case .idle, .pending, .failed:
            false
        }
    }

    var purchaseButtonLabel: String {
        if let lifetimeProduct {
            return "Unlock for \(lifetimeProduct.displayPrice)"
        }
        if let previewDisplayPrice {
            return "Unlock for \(previewDisplayPrice)"
        }
        return "Unlock Lifetime Access"
    }

    var productPriceLabel: String? {
        lifetimeProduct?.displayPrice ?? previewDisplayPrice
    }

    var analyticsAccessState: AgenTTYAnalyticsAccessState {
        AgenTTYAnalyticsAccessState(
            hasFinishedInitialAccessLoad: hasFinishedInitialAccessLoad,
            hasLifetimeAccess: hasLifetimeAccess,
            trialExpired: trialStatus?.isExpired ?? false,
            trialConsumedUsageSeconds: trialStatus?.consumedUsage ?? 0,
            trialRemainingUsageSeconds: trialStatus?.remainingUsage ?? 0,
            interactiveContentAllowed: shouldRenderInteractiveContent,
            gateBlocking: shouldBlockWithGate
        )
    }

    var statusMessage: String? {
        switch flowState {
        case .idle:
            return productLoadErrorMessage
        case .pending:
            return "The purchase is pending approval. Access unlocks automatically once Apple completes it."
        case .failed(let message):
            return message
        case .purchasing, .restoring:
            return nil
        }
    }

    func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
        updateUsageMeteringState()
    }

    func refreshForForeground() async {
        guard enforcesLifetimeAccessPaywall else { return }
        if !hasFinishedInitialAccessLoad, let startupTask {
            await startupTask.value
            return
        }
        await refreshAccessState(reason: "foreground")
        await loadProductIfNeeded(force: false)
    }

    func allowsExternalAction() async -> Bool {
        guard enforcesLifetimeAccessPaywall else { return true }
        if !hasFinishedInitialAccessLoad, let startupTask {
            await startupTask.value
        } else {
            await refreshAccessState(reason: "external_action")
        }
        return shouldRenderInteractiveContent
    }

    func retryFromPaywall() async {
        guard enforcesLifetimeAccessPaywall else { return }
        flowState = .idle
        productLoadErrorMessage = nil
        async let accessRefresh: AgenTTYLifetimeEntitlementLookup = refreshAccessState(
            reason: "manual_retry"
        )
        async let productRefresh: Void = loadProductIfNeeded(force: true)
        _ = await (accessRefresh, productRefresh)
    }

    func purchaseLifetimeAccess() async {
        guard enforcesLifetimeAccessPaywall else { return }
        guard !isWorking else { return }

        flowState = .purchasing
        productLoadErrorMessage = nil
        recordPurchaseFlow(kind: .purchase, state: .attempted)
        if lifetimeProduct == nil {
            await loadProductIfNeeded(force: true)
        }

        guard let lifetimeProduct else {
            flowState = .failed("The App Store product is unavailable right now. Please try again.")
            return
        }

        do {
            let result = try await lifetimeProduct.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.requireVerified(verification)
                handleVerifiedLifetimeTransaction(transaction)
                await transaction.finish()
                flowState = .idle
                recordPurchaseFlow(kind: .purchase, state: .success)
            case .pending:
                flowState = .pending
                recordPurchaseFlow(kind: .purchase, state: .pending)
                await refreshAccessState(reason: "purchase_pending")
            case .userCancelled:
                flowState = .idle
                recordPurchaseFlow(kind: .purchase, state: .cancelled)
            @unknown default:
                flowState = .failed("The App Store returned an unexpected purchase result.")
                recordPurchaseFlow(
                    kind: .purchase,
                    state: .failed,
                    errorMessage: "unexpected_purchase_result"
                )
            }
        } catch {
            EsmaLog.app.error(
                "event=lifetime_access_purchase_failed error=\(String(describing: error), privacy: .public)"
            )
            flowState = .failed("The purchase failed. Please try again.")
            recordPurchaseFlow(
                kind: .purchase,
                state: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }

    func restorePurchases() async {
        guard enforcesLifetimeAccessPaywall else { return }
        guard !isWorking else { return }

        flowState = .restoring
        productLoadErrorMessage = nil
        recordPurchaseFlow(kind: .restore, state: .attempted)
        do {
            try await AppStore.sync()
            let lookup = await refreshAccessState(reason: "restore")
            if hasLifetimeAccess {
                flowState = .idle
                recordPurchaseFlow(kind: .restore, state: .success)
            } else if lookup == .inconclusive {
                flowState = .failed("The App Store couldn’t verify purchases right now. Please try again.")
                recordPurchaseFlow(kind: .restore, state: .failed, errorMessage: "inconclusive_lookup")
            } else {
                flowState = .failed("No lifetime purchase was found for this Apple Account.")
                recordPurchaseFlow(kind: .restore, state: .notFound)
            }
        } catch {
            EsmaLog.app.error(
                "event=lifetime_access_restore_failed error=\(String(describing: error), privacy: .public)"
            )
            flowState = .failed("Restore failed. Please try again.")
            recordPurchaseFlow(
                kind: .restore,
                state: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func performInitialLoad() async {
        async let accessRefresh: AgenTTYLifetimeEntitlementLookup = refreshAccessState(
            reason: "startup",
            allowsInitialGracePeriod: true
        )
        async let productRefresh: Void = loadProductIfNeeded(force: false)
        _ = await (accessRefresh, productRefresh)
    }

    @discardableResult
    private func refreshAccessState(
        reason: StaticString,
        allowsInitialGracePeriod: Bool = false
    ) async -> AgenTTYLifetimeEntitlementLookup {
        checkpointActiveUsageIfNeeded(reason: reason)

        let now = Date()
        let trialRecord = trialRecordStore.loadCurrentRecord(now: now)
        let trialStatus = AgenTTYTrialPolicy.status(for: trialRecord)
        currentTrialRecord = trialRecord
        self.trialStatus = trialStatus

        var lookup = await Self.lookupLifetimeEntitlement()
        if allowsInitialGracePeriod,
           trialStatus.isExpired,
           !hasLifetimeAccess,
           lookup == .absent || lookup == .inconclusive {
            do {
                try await Task.sleep(for: Self.initialEntitlementGracePeriod)
            } catch {
                return lookup
            }

            if hasLifetimeAccess {
                lookup = .active
            } else {
                lookup = await Self.lookupLifetimeEntitlement()
            }
        }

        hasLifetimeAccess = AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
            currentValue: hasLifetimeAccess,
            lookup: lookup
        )
        hasFinishedInitialAccessLoad = true
        updateUsageMeteringState()

        EsmaLog.app.notice(
            "event=lifetime_access_refresh reason=\(String(describing: reason), privacy: .public) lookup=\(String(describing: lookup), privacy: .public) unlocked=\(self.hasLifetimeAccess, privacy: .public) expired=\(trialStatus.isExpired, privacy: .public) consumed_usage=\(trialStatus.consumedUsage, privacy: .public) remaining_usage=\(trialStatus.remainingUsage, privacy: .public)"
        )
        recordAccessStateSnapshot(reason: String(describing: reason))
        return lookup
    }

    private func loadProductIfNeeded(force: Bool) async {
        guard enforcesLifetimeAccessPaywall else { return }
        if !force, lifetimeProduct != nil {
            return
        }

        do {
            let products = try await Product.products(for: [AgenTTYLifetimeAccessProduct.productID])
            lifetimeProduct = products.first(where: { $0.id == AgenTTYLifetimeAccessProduct.productID })
            if lifetimeProduct == nil {
                productLoadErrorMessage = "The lifetime access product is not configured in the App Store yet."
            } else {
                productLoadErrorMessage = nil
            }
        } catch {
            EsmaLog.app.error(
                "event=lifetime_access_product_load_failed error=\(String(describing: error), privacy: .public)"
            )
            productLoadErrorMessage = "Couldn’t load the App Store price. Check your connection and try again."
        }
    }

    private func startTransactionListener() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try Self.requireVerified(update)
                    guard transaction.productID == AgenTTYLifetimeAccessProduct.productID else {
                        continue
                    }
                    self.handleVerifiedLifetimeTransaction(transaction)
                    await transaction.finish()
                } catch {
                    EsmaLog.app.error(
                        "event=lifetime_access_transaction_update_failed error=\(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
    }

    private static func lookupLifetimeEntitlement() async -> AgenTTYLifetimeEntitlementLookup {
        var encounteredUnverifiedTransaction = false
        for await result in Transaction.currentEntitlements(for: AgenTTYLifetimeAccessProduct.productID) {
            switch result {
            case .verified(let transaction):
                return transaction.revocationDate == nil ? .active : .revoked
            case .unverified:
                encounteredUnverifiedTransaction = true
            }
        }

        if let latest = await Transaction.latest(for: AgenTTYLifetimeAccessProduct.productID) {
            switch latest {
            case .verified(let transaction):
                return transaction.revocationDate == nil ? .active : .revoked
            case .unverified:
                return .inconclusive
            }
        }

        return encounteredUnverifiedTransaction ? .inconclusive : .absent
    }

    private func handleVerifiedLifetimeTransaction(_ transaction: Transaction) {
        guard transaction.productID == AgenTTYLifetimeAccessProduct.productID else { return }

        let lookup: AgenTTYLifetimeEntitlementLookup = transaction.revocationDate == nil
            ? .active
            : .revoked
        hasLifetimeAccess = AgenTTYLifetimeAccessPolicy.reconciledLifetimeAccess(
            currentValue: hasLifetimeAccess,
            lookup: lookup
        )
        updateUsageMeteringState()

        EsmaLog.app.notice(
            "event=lifetime_access_transaction_applied lookup=\(String(describing: lookup), privacy: .public) transaction_id=\(transaction.id, privacy: .public)"
        )
    }

    nonisolated private static func requireVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }

    private var shouldMeterUsage: Bool {
        guard enforcesLifetimeAccessPaywall else { return false }
        guard hasFinishedInitialAccessLoad else { return false }
        guard isSceneActive else { return false }
        guard !hasLifetimeAccess else { return false }
        guard let trialStatus else { return false }
        return !trialStatus.isExpired
    }

    private func updateUsageMeteringState() {
        guard shouldMeterUsage else {
            endActiveUsageSessionIfNeeded(reason: "metering_disabled")
            stopUsageCheckpointTask()
            return
        }

        beginActiveUsageSessionIfNeeded()
        startUsageCheckpointTaskIfNeeded()
    }

    private func beginActiveUsageSessionIfNeeded() {
        guard shouldMeterUsage else { return }
        guard activeUsageSessionStart == nil else { return }
        activeUsageSessionStart = AgenTTYUsageTrialSessionStart(
            wallClockStartedAt: Date(),
            systemUptimeStartedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    private func checkpointActiveUsageIfNeeded(reason: StaticString) {
        guard let activeUsageSessionStart, let currentTrialRecord else { return }

        let now = Date()
        let systemUptime = ProcessInfo.processInfo.systemUptime
        let elapsedUsage = AgenTTYTrialPolicy.measuredElapsedUsage(
            wallClockStartedAt: activeUsageSessionStart.wallClockStartedAt,
            systemUptimeStartedAt: activeUsageSessionStart.systemUptimeStartedAt,
            now: now,
            systemUptime: systemUptime
        )
        guard elapsedUsage > 0 else { return }

        let updatedTrialRecord = AgenTTYTrialPolicy.updatedRecord(
            from: currentTrialRecord,
            adding: elapsedUsage
        )
        let updatedTrialStatus = AgenTTYTrialPolicy.status(for: updatedTrialRecord)

        self.currentTrialRecord = updatedTrialRecord
        trialStatus = updatedTrialStatus
        trialRecordStore.persist(updatedTrialRecord)

        EsmaLog.app.notice(
            "event=lifetime_access_trial_usage_checkpoint reason=\(String(describing: reason), privacy: .public) consumed_usage=\(updatedTrialStatus.consumedUsage, privacy: .public) remaining_usage=\(updatedTrialStatus.remainingUsage, privacy: .public)"
        )

        if updatedTrialStatus.isExpired {
            self.activeUsageSessionStart = nil
            stopUsageCheckpointTask()
            return
        }

        self.activeUsageSessionStart = AgenTTYUsageTrialSessionStart(
            wallClockStartedAt: now,
            systemUptimeStartedAt: systemUptime
        )
    }

    private func endActiveUsageSessionIfNeeded(reason: StaticString) {
        checkpointActiveUsageIfNeeded(reason: reason)
        activeUsageSessionStart = nil
    }

    private func startUsageCheckpointTaskIfNeeded() {
        guard usageCheckpointTask == nil else { return }

        usageCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                guard !Task.isCancelled else { return }
                self.handleUsageCheckpointTick()
            }
        }
    }

    private func stopUsageCheckpointTask() {
        usageCheckpointTask?.cancel()
        usageCheckpointTask = nil
    }

    private func handleUsageCheckpointTick() {
        guard shouldMeterUsage else {
            stopUsageCheckpointTask()
            return
        }

        checkpointActiveUsageIfNeeded(reason: "periodic")

        if !shouldMeterUsage {
            stopUsageCheckpointTask()
        }
    }

    private func recordPurchaseFlow(
        kind: AgenTTYAnalyticsPurchaseFlowKind,
        state: AgenTTYAnalyticsPurchaseFlowState,
        errorMessage: String? = nil
    ) {
        guard let analyticsClient else { return }
        Task {
            await analyticsClient.recordPurchaseFlow(
                AgenTTYAnalyticsPurchaseFlowEvent(
                    kind: kind,
                    state: state,
                    errorMessage: errorMessage
                )
            )
        }
    }

    private func recordAccessStateSnapshot(reason: String) {
        guard let analyticsClient else { return }
        let accessState = analyticsAccessState
        Task {
            await analyticsClient.recordAccessStateSnapshot(
                AgenTTYAnalyticsAccessStateSnapshotEvent(
                    reason: reason,
                    accessState: accessState
                )
            )
        }
    }
}

#if DEBUG
@MainActor
extension AgenTTYLifetimeAccessController {
    static func previewExpiredTrial(displayPrice: String = "$4.99") -> AgenTTYLifetimeAccessController {
        let now = Date()
        return AgenTTYLifetimeAccessController(
            previewDisplayPrice: displayPrice,
            previewHasLifetimeAccess: false,
            previewTrialStatus: AgenTTYTrialStatus(
                startedAt: now.addingTimeInterval(-24 * 60 * 60),
                usageLimit: AgenTTYTrialPolicy.usageLimit,
                consumedUsage: AgenTTYTrialPolicy.usageLimit
            )
        )
    }

    static func previewUnlocked() -> AgenTTYLifetimeAccessController {
        AgenTTYLifetimeAccessController(
            previewDisplayPrice: nil,
            previewHasLifetimeAccess: true,
            previewTrialStatus: nil
        )
    }
}
#endif
