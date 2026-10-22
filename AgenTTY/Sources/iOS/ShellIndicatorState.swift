import Foundation
import Observation
import CoreGraphics

@MainActor
@Observable
final class ShellIndicatorState {
    static let createShellPlaceholderWindowID = Int.min

    enum ShellTitleSlideDirection: Equatable {
        case none
        case forward
        case backward
    }

    struct SpacebarShellCard: Identifiable, Equatable {
        let windowID: Int
        let position: Int
        let title: String
        let isActive: Bool
        let isProvisional: Bool
        let isCreatePlaceholder: Bool

        var id: Int { windowID }
    }

    private struct ShellContext: Equatable {
        let workingDirectoryPath: String
        let branchName: String?
    }

    private(set) var windowCount = 0
    private(set) var activePosition = 0
    private(set) var activeWindowId: Int?
    private(set) var unreadPositions: Set<Int> = []
    private(set) var isSwipeEmphasized = false
    private(set) var activeShellTitle = ""
    private(set) var activeShellTitleSlideDirection: ShellTitleSlideDirection = .none
    private(set) var activeShellSwipePreviewProgress: CGFloat = 0
    private(set) var activeShellSwipeReleaseVelocityX: CGFloat = 0
    private(set) var activeWorkingDirectoryLabel = ""
    private(set) var activeGitBranchLabel = ""
    private(set) var spacebarShellCards: [SpacebarShellCard] = []

    @ObservationIgnored
    private var canonicalWindowIds: [Int] = []
    @ObservationIgnored
    private var displayedWindowIds: [Int] = []
    @ObservationIgnored
    private var provisionalWindowIds: Set<Int> = []
    @ObservationIgnored
    private var unreadWindowIds: Set<Int> = []
    @ObservationIgnored
    private var shellTitlesByWindowID: [Int: String] = [:]
    @ObservationIgnored
    private var shellContextsByWindowID: [Int: ShellContext] = [:]
    @ObservationIgnored
    private var lastReportedSpacebarTitleCharacterLimit: Int?
    @ObservationIgnored
    private var swipeEmphasisResetWorkItem: DispatchWorkItem?
    @ObservationIgnored
    private let swipeEmphasisHoldDuration: TimeInterval = 0.75
    @ObservationIgnored
    private let shellTitleAIEnabled: Bool
    @ObservationIgnored
    private static let swipePreviewProgressTolerance: CGFloat = 0.001
    @ObservationIgnored
    private static let swipeReleaseVelocityTolerance: CGFloat = 0.25
    @ObservationIgnored
    private static let abbreviatedHomeDirectoryRoots: Set<String> = ["Users", "home"]

    init(shellTitleAIEnabled: Bool = AgenTTYFeatureFlags.shellTitleAIEnabled) {
        self.shellTitleAIEnabled = shellTitleAIEnabled
    }

    var displayedWindowIDs: [Int] {
        displayedWindowIds
    }

    var navigateToWindow: ((Int) -> Void)?
    var createAndNavigateToNewWindow: (() -> Void)?
    var spacebarTitleCharacterLimitDidChange: ((Int) -> Void)?

    func update(windowCount _: Int, activePosition: Int, windowIds: [Int]) {
        let previousWindowIds = displayedWindowIds
        let previousActivePosition = self.activePosition
        if canonicalWindowIds != windowIds {
            canonicalWindowIds = windowIds
        }
        if displayedWindowIds != windowIds {
            displayedWindowIds = windowIds
        }
        if !provisionalWindowIds.isEmpty {
            provisionalWindowIds.removeAll(keepingCapacity: false)
        }
        let normalizedPosition = normalizedActivePosition(
            activePosition,
            windowCount: displayedWindowIds.count
        )
        if windowCount != displayedWindowIds.count {
            windowCount = displayedWindowIds.count
        }
        if self.activePosition != normalizedPosition {
            self.activePosition = normalizedPosition
        }

        recomputeDisplayedStateSnapshots()

        let liveWindowIDSet = Set(windowIds)
        let filteredTitles = shellTitlesByWindowID.filter { liveWindowIDSet.contains($0.key) }
        if filteredTitles != shellTitlesByWindowID {
            shellTitlesByWindowID = filteredTitles
        }
        let filteredContexts = shellContextsByWindowID.filter { liveWindowIDSet.contains($0.key) }
        if filteredContexts != shellContextsByWindowID {
            shellContextsByWindowID = filteredContexts
        }

        if self.activePosition < displayedWindowIds.count {
            unreadWindowIds.remove(displayedWindowIds[self.activePosition])
        }
        recomputeActiveShellTitleSlideDirection(
            previousWindowIds: previousWindowIds,
            previousActivePosition: previousActivePosition
        )
        recomputeUnreadPositions()
        recomputeActiveShellTitle()
        recomputeActiveShellContextLabels()
    }

    func applyOptimistic(windowIds: [Int], activePosition: Int) {
        let previousWindowIds = displayedWindowIds
        let previousActivePosition = self.activePosition
        if displayedWindowIds != windowIds {
            displayedWindowIds = windowIds
        }
        let canonicalWindowIDSet = Set(canonicalWindowIds)
        let nextProvisionalWindowIds = Set(windowIds.filter { !canonicalWindowIDSet.contains($0) })
        if provisionalWindowIds != nextProvisionalWindowIds {
            provisionalWindowIds = nextProvisionalWindowIds
        }
        if windowCount != displayedWindowIds.count {
            windowCount = displayedWindowIds.count
        }
        let normalizedPosition = normalizedActivePosition(
            activePosition,
            windowCount: displayedWindowIds.count
        )
        if self.activePosition != normalizedPosition {
            self.activePosition = normalizedPosition
        }

        recomputeDisplayedStateSnapshots()

        if self.activePosition < displayedWindowIds.count {
            unreadWindowIds.remove(displayedWindowIds[self.activePosition])
        }
        recomputeActiveShellTitleSlideDirection(
            previousWindowIds: previousWindowIds,
            previousActivePosition: previousActivePosition
        )
        recomputeUnreadPositions()
        recomputeActiveShellTitle()
        recomputeActiveShellContextLabels()
    }

    func markUnread(_ windowId: Int) {
        if unreadWindowIds.insert(windowId).inserted {
            recomputeUnreadPositions()
        }
    }

    func navigateAndClearUnread(_ windowId: Int) {
        if windowId == Self.createShellPlaceholderWindowID {
            createAndNavigateToNewWindow?()
            return
        }

        guard canonicalWindowIds.contains(windowId) else { return }
        navigateToWindow?(windowId)
        if unreadWindowIds.remove(windowId) != nil {
            recomputeUnreadPositions()
        }
    }

    func windowId(at position: Int) -> Int? {
        guard position >= 0, position < displayedWindowIds.count else { return nil }
        return displayedWindowIds[position]
    }

    func updateWindowTitle(windowID: Int, title: String) {
        guard shellTitleAIEnabled else { return }
        guard canonicalWindowIds.contains(windowID) else { return }
        let isActiveWindow = windowID == activeWindowId

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.isEmpty {
            if shellTitlesByWindowID.removeValue(forKey: windowID) != nil {
                if isActiveWindow {
                    setActiveShellTitleSlideDirection(.none)
                }
                recomputeDisplayedStateSnapshots()
                recomputeActiveShellTitle()
            }
            return
        }

        if shellTitlesByWindowID[windowID] == normalizedTitle {
            return
        }

        shellTitlesByWindowID[windowID] = normalizedTitle
        if isActiveWindow {
            setActiveShellTitleSlideDirection(.none)
        }
        recomputeDisplayedStateSnapshots()
        recomputeActiveShellTitle()
    }

    func updateWindowWorkingDirectory(windowID: Int, workingDirectoryPath: String) {
        let normalizedPath = Self.normalizeWorkingDirectoryPath(workingDirectoryPath)
        let existingContext = shellContextsByWindowID[windowID]
        let existingBranchName: String?
        if existingContext?.workingDirectoryPath == normalizedPath {
            existingBranchName = existingContext?.branchName
        } else {
            existingBranchName = nil
        }
        updateWindowContext(
            windowID: windowID,
            workingDirectoryPath: normalizedPath,
            branchName: existingBranchName
        )
    }

    func updateWindowContext(windowID: Int, workingDirectoryPath: String, branchName: String?) {
        guard canonicalWindowIds.contains(windowID) else { return }

        let normalizedPath = Self.normalizeWorkingDirectoryPath(workingDirectoryPath)
        let normalizedBranchName = Self.normalizeBranchName(branchName)
        let previousContext = shellContextsByWindowID[windowID]
        let nextContext = ShellContext(
            workingDirectoryPath: normalizedPath,
            branchName: normalizedBranchName
        )

        if previousContext == nextContext {
            return
        }

        shellContextsByWindowID[windowID] = nextContext
        if previousContext?.workingDirectoryPath != normalizedPath {
            recomputeDisplayedStateSnapshots()
        }
        if windowID == activeWindowId {
            recomputeActiveShellContextLabels()
        }
    }

    func reportSpacebarTitleCharacterLimit(_ maxCharacters: Int) {
        let normalizedLimit = max(maxCharacters, 1)
        guard lastReportedSpacebarTitleCharacterLimit != normalizedLimit else { return }
        lastReportedSpacebarTitleCharacterLimit = normalizedLimit
        spacebarTitleCharacterLimitDidChange?(normalizedLimit)
    }

    func beginSwipeIndicatorEmphasis() {
        swipeEmphasisResetWorkItem?.cancel()
        swipeEmphasisResetWorkItem = nil
        if !isSwipeEmphasized {
            isSwipeEmphasized = true
        }
    }

    func updateActiveShellSwipePreview(translationX: CGFloat, viewWidth: CGFloat) {
        guard viewWidth > 0 else {
            if abs(activeShellSwipePreviewProgress) > Self.swipePreviewProgressTolerance {
                activeShellSwipePreviewProgress = 0
            }
            return
        }
        let normalizedProgress = max(min(translationX / viewWidth, 1), -1)
        if abs(activeShellSwipePreviewProgress - normalizedProgress) > Self.swipePreviewProgressTolerance {
            activeShellSwipePreviewProgress = normalizedProgress
        }
    }

    func updateActiveShellSwipeReleaseVelocity(velocityX: CGFloat) {
        guard velocityX.isFinite else {
            if abs(activeShellSwipeReleaseVelocityX) > Self.swipeReleaseVelocityTolerance {
                activeShellSwipeReleaseVelocityX = 0
            }
            return
        }
        if abs(activeShellSwipeReleaseVelocityX - velocityX) > Self.swipeReleaseVelocityTolerance {
            activeShellSwipeReleaseVelocityX = velocityX
        }
    }

    func cancelActiveShellSwipePreview() {
        if abs(activeShellSwipePreviewProgress) > Self.swipePreviewProgressTolerance {
            activeShellSwipePreviewProgress = 0
        }
        if abs(activeShellSwipeReleaseVelocityX) > Self.swipeReleaseVelocityTolerance {
            activeShellSwipeReleaseVelocityX = 0
        }
    }

    func endSwipeIndicatorEmphasis() {
        swipeEmphasisResetWorkItem?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.swipeEmphasisResetWorkItem = nil
            self.isSwipeEmphasized = false
        }
        swipeEmphasisResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + swipeEmphasisHoldDuration, execute: work)
    }

    private func recomputeUnreadPositions() {
        var positions: Set<Int> = []
        for (i, id) in displayedWindowIds.enumerated() {
            if unreadWindowIds.contains(id) {
                positions.insert(i)
            }
        }
        if unreadPositions != positions {
            unreadPositions = positions
        }
    }

    private func recomputeDisplayedStateSnapshots() {
        let nextActiveWindowID: Int?
        if activePosition >= 0, activePosition < displayedWindowIds.count {
            nextActiveWindowID = displayedWindowIds[activePosition]
        } else {
            nextActiveWindowID = nil
        }
        if activeWindowId != nextActiveWindowID {
            activeWindowId = nextActiveWindowID
        }

        let existingShellCards = displayedWindowIds.enumerated().map { position, windowID in
            return SpacebarShellCard(
                windowID: windowID,
                position: position,
                title: quickSwitcherCardTitle(windowID: windowID, position: position),
                isActive: position == activePosition,
                isProvisional: provisionalWindowIds.contains(windowID),
                isCreatePlaceholder: false
            )
        }

        let nextSpacebarShellCards: [SpacebarShellCard]
        if existingShellCards.isEmpty {
            nextSpacebarShellCards = []
        } else {
            let createPlaceholderCard = SpacebarShellCard(
                windowID: Self.createShellPlaceholderWindowID,
                position: existingShellCards.count,
                title: "",
                isActive: false,
                isProvisional: false,
                isCreatePlaceholder: true
            )
            nextSpacebarShellCards = existingShellCards + [createPlaceholderCard]
        }

        if spacebarShellCards != nextSpacebarShellCards {
            spacebarShellCards = nextSpacebarShellCards
        }
    }

    private func recomputeActiveShellTitle() {
        let nextTitle: String
        let nextDirection: ShellTitleSlideDirection

        guard shellTitleAIEnabled else {
            nextTitle = ""
            nextDirection = .none
            applyActiveShellTitleState(nextTitle: nextTitle, nextDirection: nextDirection)
            return
        }

        guard activePosition >= 0, activePosition < displayedWindowIds.count else {
            nextTitle = ""
            nextDirection = .none
            applyActiveShellTitleState(nextTitle: nextTitle, nextDirection: nextDirection)
            return
        }
        let activeWindowID = displayedWindowIds[activePosition]
        guard canonicalWindowIds.contains(activeWindowID) else {
            nextTitle = ""
            nextDirection = .none
            applyActiveShellTitleState(nextTitle: nextTitle, nextDirection: nextDirection)
            return
        }
        nextTitle = shellTitlesByWindowID[activeWindowID] ?? ""
        nextDirection = activeShellTitleSlideDirection
        applyActiveShellTitleState(nextTitle: nextTitle, nextDirection: nextDirection)
    }

    private func recomputeActiveShellContextLabels() {
        guard activePosition >= 0, activePosition < displayedWindowIds.count else {
            applyActiveShellContextLabels(workingDirectory: "", branch: "")
            return
        }
        let activeWindowID = displayedWindowIds[activePosition]
        guard canonicalWindowIds.contains(activeWindowID),
              let context = shellContextsByWindowID[activeWindowID]
        else {
            applyActiveShellContextLabels(workingDirectory: "", branch: "")
            return
        }

        let nextWorkingDirectory = Self.workingDirectoryLabel(from: context.workingDirectoryPath)
        let nextBranch = context.branchName ?? ""
        applyActiveShellContextLabels(
            workingDirectory: nextWorkingDirectory,
            branch: nextBranch
        )
    }

    private func recomputeActiveShellTitleSlideDirection(
        previousWindowIds: [Int],
        previousActivePosition: Int
    ) {
        guard previousActivePosition >= 0, previousActivePosition < previousWindowIds.count else {
            setActiveShellTitleSlideDirection(.none)
            return
        }
        guard activePosition >= 0, activePosition < displayedWindowIds.count else {
            setActiveShellTitleSlideDirection(.none)
            return
        }

        let previousWindowID = previousWindowIds[previousActivePosition]
        let newWindowID = displayedWindowIds[activePosition]
        guard previousWindowID != newWindowID else {
            setActiveShellTitleSlideDirection(.none)
            return
        }

        if let newIndexInPrevious = previousWindowIds.firstIndex(of: newWindowID) {
            let delta = newIndexInPrevious - previousActivePosition
            if delta == 1 {
                setActiveShellTitleSlideDirection(.forward)
                return
            }
            if delta == -1 {
                setActiveShellTitleSlideDirection(.backward)
                return
            }
            setActiveShellTitleSlideDirection(.none)
            return
        }

        let didAppendOneWindow =
            displayedWindowIds.count == previousWindowIds.count + 1 &&
            displayedWindowIds.starts(with: previousWindowIds)
        let movedOneStepForward = activePosition == previousActivePosition + 1
        if didAppendOneWindow && movedOneStepForward && activePosition == displayedWindowIds.count - 1 {
            setActiveShellTitleSlideDirection(.forward)
            return
        }

        setActiveShellTitleSlideDirection(.none)
    }

    private func applyActiveShellTitleState(
        nextTitle: String,
        nextDirection: ShellTitleSlideDirection
    ) {
        if activeShellTitle != nextTitle {
            activeShellTitle = nextTitle
        }
        setActiveShellTitleSlideDirection(nextDirection)
    }

    private func setActiveShellTitleSlideDirection(_ direction: ShellTitleSlideDirection) {
        if activeShellTitleSlideDirection != direction {
            activeShellTitleSlideDirection = direction
        }
    }

    private func applyActiveShellContextLabels(workingDirectory: String, branch: String) {
        if activeWorkingDirectoryLabel != workingDirectory {
            activeWorkingDirectoryLabel = workingDirectory
        }
        if activeGitBranchLabel != branch {
            activeGitBranchLabel = branch
        }
    }

    private func normalizedActivePosition(_ proposed: Int, windowCount: Int) -> Int {
        guard windowCount > 0 else { return 0 }
        return min(max(proposed, 0), windowCount - 1)
    }

    private func quickSwitcherCardTitle(windowID: Int, position: Int) -> String {
        let rawTitle = shellTitlesByWindowID[windowID] ?? ""
        let normalizedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedTitle.isEmpty {
            return normalizedTitle
        }

        if let context = shellContextsByWindowID[windowID] {
            let workingDirectoryTitle = Self.quickSwitcherWorkingDirectoryLabel(
                from: context.workingDirectoryPath
            )
            if !workingDirectoryTitle.isEmpty {
                return workingDirectoryTitle
            }
        }

        return "shell \(position + 1)"
    }

    private static func normalizeWorkingDirectoryPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeBranchName(_ branchName: String?) -> String? {
        guard let branchName else { return nil }
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func quickSwitcherWorkingDirectoryLabel(from path: String) -> String {
        let normalizedPath = normalizeWorkingDirectoryPath(path)
        guard !normalizedPath.isEmpty else { return "" }
        guard normalizedPath != "/" else { return "/" }

        if normalizedPath == "~" || normalizedPath.hasPrefix("~/") {
            return normalizedPath
        }

        let pathComponents = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let firstComponent = pathComponents.first else {
            return normalizedPath
        }

        if pathComponents.count >= 2,
           abbreviatedHomeDirectoryRoots.contains(String(firstComponent))
        {
            let remainder = pathComponents.dropFirst(2).joined(separator: "/")
            return remainder.isEmpty ? "~" : "~/" + remainder
        }

        return normalizedPath
    }

    private static func workingDirectoryLabel(from path: String) -> String {
        let normalizedPath = normalizeWorkingDirectoryPath(path)
        guard !normalizedPath.isEmpty else { return "" }
        guard normalizedPath != "/" else { return "/" }

        if let leafComponent = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).last {
            return String(leafComponent)
        }

        return normalizedPath
    }
}
