import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct ContentRetentionPolicyTests {
  @Test func rendererEstimateIncludesOverheadAndSaturatesOnOverflow() {
    #expect(
      ContentRetentionPolicy.terminalBytes(displayedTargetBytes: 1_024) == 12 * 1_024 * 1_024
        + 8_192)
    #expect(ContentRetentionPolicy.terminalBytes(displayedTargetBytes: .max) == .max)
    #expect(ContentRetentionPolicy.terminalBytes(displayedTargetBytes: .max / 8) == .max)
  }

  @Test func viewTreeBackstopAppliesEvenWhenEveryCandidateIsFree() {
    let candidates = (0..<40).map {
      ContentRetentionPolicy.Candidate(id: Worktree.ID("/tmp/free-\($0)"), estimatedBytes: 0)
    }
    let retained = ContentRetentionPolicy(budgetBytes: .max).retained(
      candidates, selected: candidates.last?.id)
    #expect(retained.count == ContentRetentionPolicy.maximumWorktrees)
    #expect(retained.first == candidates.last?.id)
    #expect(Set(retained).count == retained.count)
  }

  @Test func duplicateCandidatesConsumeTheirBudgetOnlyOnce() {
    let candidate = ContentRetentionPolicy.Candidate(
      id: Worktree.ID("duplicate"), estimatedBytes: 40)
    let other = ContentRetentionPolicy.Candidate(id: Worktree.ID("other"), estimatedBytes: 50)
    #expect(
      ContentRetentionPolicy(budgetBytes: 100).retained(
        [candidate, candidate, other], selected: nil) == [candidate.id, other.id])
  }

  @Test func cheapSessionsSurviveBeyondEightWorktrees() {
    let policy = ContentRetentionPolicy(budgetBytes: 100)
    let candidates = (0..<12).map {
      ContentRetentionPolicy.Candidate(id: Worktree.ID("/tmp/cheap-\($0)"), estimatedBytes: 5)
    }
    #expect(policy.retained(candidates, selected: candidates[0].id) == candidates.map(\.id))
  }

  @Test func oversizedOlderSessionsDoNotDisplaceAffordableRecentContent() {
    let policy = ContentRetentionPolicy(budgetBytes: 100)
    // Enough affordable candidates that the budget pass alone clears the floor,
    // so this asserts budget precedence rather than the floor.
    let candidates = [
      ContentRetentionPolicy.Candidate(id: Worktree.ID("selected"), estimatedBytes: 40),
      ContentRetentionPolicy.Candidate(id: Worktree.ID("expensive"), estimatedBytes: 80),
      ContentRetentionPolicy.Candidate(id: Worktree.ID("affordable"), estimatedBytes: 50),
      ContentRetentionPolicy.Candidate(id: Worktree.ID("over-budget"), estimatedBytes: 20),
      ContentRetentionPolicy.Candidate(id: Worktree.ID("spare"), estimatedBytes: 5),
    ]
    #expect(
      policy.retained(candidates, selected: Worktree.ID("selected")) == [
        Worktree.ID("selected"), Worktree.ID("affordable"), Worktree.ID("spare"),
      ])
  }

  @Test func retentionKeepsAFloorWhenEveryCandidateExceedsTheBudget() {
    // A single full-screen pane on a large display estimates in the hundreds of
    // megabytes and alone exhausts a 16 GB machine's 512 MiB budget. Without a
    // floor only the selected worktree is retained and every switch pays a full
    // tree remount, reinstating the cost retention exists to remove.
    let policy = ContentRetentionPolicy(budgetBytes: 512 * 1024 * 1024)
    let perWorktree = ContentRetentionPolicy.terminalBytes(
      displayedTargetBytes: 47 * 1024 * 1024)
    let candidates = (0..<5).map {
      ContentRetentionPolicy.Candidate(
        id: Worktree.ID("/tmp/large-\($0)"), estimatedBytes: perWorktree)
    }
    #expect(perWorktree > policy.budgetBytes / 2)
    let retained = policy.retained(candidates, selected: candidates[0].id)
    #expect(retained.count == ContentRetentionPolicy.minimumWorktrees)
    #expect(retained.first == candidates[0].id)
    #expect(Set(retained).count == retained.count)
  }

  @Test func selectionSurvivesEvenWhenItExceedsTheBudget() {
    let policy = ContentRetentionPolicy(budgetBytes: 100)
    let candidates = [
      ContentRetentionPolicy.Candidate(id: Worktree.ID("old"), estimatedBytes: 10),
      ContentRetentionPolicy.Candidate(id: Worktree.ID("selected"), estimatedBytes: .max),
    ]
    let retained = policy.retained(candidates, selected: Worktree.ID("selected"))
    #expect(retained.first == Worktree.ID("selected"))
    // A selection that saturates the budget leaves nothing for the rest, so the
    // floor is the only reason the neighbour is still retained.
    #expect(retained == [Worktree.ID("selected"), Worktree.ID("old")])
  }
}

@MainActor
struct TerminalsFeatureTests {
  /// Minimal live content whose renderer and eligibility the tests control.
  @MainActor
  private final class HibernatableContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    /// Eligibility knob for the fire-time re-arm path.
    var claimsHibernation = true
    var estimatedRetentionBytes = ContentRetentionPolicy.unknownContentBytes
    private(set) var startCalls = 0
    private(set) var rendererReads = 0
    private var view: NSView?
    private let state: TerminalContentState

    init(id: ContentID, state: TerminalContentState = TerminalContentState(workingDirectory: nil)) {
      self.id = id
      self.state = state
    }

    var renderer: NSView? {
      rendererReads += 1
      return view
    }
    var isHibernatable: Bool { view != nil && claimsHibernation }

    func startSession(at geometry: ContentGeometry) {
      startCalls += 1
      guard view == nil else { return }
      view = NSView()
    }

    func hibernate() {
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(state))
    }
  }
  private static func layout(paneID: PaneID, tabID: TabID, contentID: ContentID) -> PaneLayout {
    PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "One",
              content: ContentSnapshot(
                id: contentID,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  // MARK: - Hibernation.

  private struct HibernationHarness {
    let store: TestStoreOf<TerminalsFeature>
    let clock: TestClock<Duration>
    let runtime: ContentRuntime
    let pressure: AsyncStream<Void>.Continuation
    let worktreeID: Worktree.ID
    let paneID: PaneID
    let selectedTab: TabID
    let hiddenTab: TabID
    let selectedContent: HibernatableContent
    let hiddenContent: HibernatableContent
  }

  /// One worktree, one pane, two tabs; both contents live in the runtime.
  private func makeHibernationHarness(startSessions: Bool = true) -> HibernationHarness {
    let worktreeID = Worktree.ID("/tmp/hib")
    let paneID = PaneID()
    let selectedTab = TabID()
    let hiddenTab = TabID()
    let selectedContent = HibernatableContent(id: ContentID())
    let hiddenContent = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    if startSessions {
      _ = runtime.provision(selectedContent, at: .fallback)
      _ = runtime.provision(hiddenContent, at: .fallback)
    }
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: selectedTab,
              title: "One",
              content: ContentSnapshot(
                id: selectedContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
            TabItem(
              id: hiddenTab,
              title: "Two",
              content: ContentSnapshot(
                id: hiddenContent.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
          ],
          selectedTabID: selectedTab
        )
      ],
      focusedPaneID: paneID
    )
    let clock = TestClock()
    let pressure = AsyncStream<Void>.makeStream()
    let warnings = pressure.stream
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[MemoryPressureClient.self] = MemoryPressureClient(warnings: { warnings })
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    return HibernationHarness(
      store: store,
      clock: clock,
      runtime: runtime,
      pressure: pressure.continuation,
      worktreeID: worktreeID,
      paneID: paneID,
      selectedTab: selectedTab,
      hiddenTab: hiddenTab,
      selectedContent: selectedContent,
      hiddenContent: hiddenContent
    )
  }

  @Test(.dependencies) func hiddenTabHibernatesAfterTheGraceWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
  }

  @Test(.dependencies) func selectingTheTabCancelsItsGraceTimer() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // Selecting the hidden tab makes it visible and hides the other one.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .selectTab(id: harness.hiddenTab)))
    ) {
      $0.layouts[id: harness.worktreeID]?.layout.panes[id: harness.paneID]?.selectedTabID = harness.hiddenTab
      $0.hibernationArmedTabs = [harness.selectedTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    // Only the newly hidden tab fires; the cancelled timer stays silent.
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer != nil)
    #expect(harness.selectedContent.renderer == nil)
  }

  @Test(.dependencies) func disablingTheFlagCancelsPendingTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.hiddenContent.renderer != nil)
  }

  @Test(.dependencies) func ineligibleHiddenTabReArmsAtFireTime() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.hiddenContent.claimsHibernation = false
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationDeferralLogged = [harness.hiddenTab]
    }
    #expect(harness.hiddenContent.renderer != nil)
    // Eligibility returns; the re-armed timer hibernates on the next window.
    harness.hiddenContent.claimsHibernation = true
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
      $0.hibernationDeferralLogged = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func selectingAWorktreeWakesItsHibernatedSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    // The wake only marks the tab; the surface arrives on a later turn.
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = [harness.selectedTab]
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.selectedContent.renderer == nil)
    await harness.clock.advance(by: LayoutFeature.wakeDeferral)
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = []
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 2
      $0.wakeRequestedTabs = []
    }
    #expect(harness.selectedContent.renderer != nil)
    // Drain the armed timer so the store finishes clean.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func deselectionPastRecencyCancelsAPendingWake() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = [harness.selectedTab]
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    // Scrub past the recency window before the wake's deferral elapses; every
    // hop but the last keeps the worktree retained, the last drops its cover.
    let limit = 8
    let others = (1...limit).map { Worktree.ID("/tmp/other-\($0)") }
    var recents = [harness.worktreeID]
    for (index, other) in others.enumerated() {
      recents.insert(other, at: 0)
      recents.removeLast(max(0, recents.count - limit))
      let expected = recents
      await harness.store.send(.selectedWorktreeChanged(other)) {
        $0.selectedWorktreeID = other
        $0.recentWorktreeIDs = expected
        // Only the first deselection releases the wake request.
        if index == 0 { $0.wakeRequestedTabs = [] }
      }
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = []
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 2
    }
    // The deferral elapsing spawns nothing: the effect died with the cancel.
    await harness.clock.advance(by: LayoutFeature.wakeDeferral)
    #expect(harness.selectedContent.renderer == nil)
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureCancelsAPendingWakeOnAHiddenTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = [harness.selectedTab]
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    // Deselect while the wake still defers; recency keeps the tab covered.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other"), harness.worktreeID]
      $0.wakeRequestedTabs = []
    }
    await harness.store.send(.task)
    harness.pressure.yield()
    // Pressure drops the recency cover and the sweep reaches the hidden pane:
    // the mid-wake tab has no renderer for the hibernatable gate, so the sweep
    // cancels its wake instead of letting the spawn land right after.
    await harness.store.receive(\.memoryPressureWarning) {
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = []
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 2
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 3
    }
    await harness.clock.advance(by: LayoutFeature.wakeDeferral)
    #expect(harness.selectedContent.renderer == nil)
    #expect(harness.hiddenContent.renderer == nil)
    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func windowedPaneKeepsItsSelectionAwakeWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      // The pane's unselected tab still hides behind its strip and arms.
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    // The window floats over any worktree; leaving this one must not arm its
    // selection.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.selectedContent.renderer != nil)
    #expect(harness.hiddenContent.renderer == nil)
  }

  @Test(.dependencies) func leavingWindowModeArmsTheSelectionOfAnUnselectedWorktree() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
    }
    // Re-attaching withdraws the exemption: the selection is hidden again.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .exitWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = []
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func windowedPaneWakesItsHibernatedSelectionWhileTheWorktreeIsUnselected() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    harness.selectedContent.hibernate()
    // Windowing a pane whose selection is hibernated must re-provision it,
    // or the window opens dead.
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .enterWindowMode(paneID: harness.paneID)))
    ) {
      $0.layouts[id: harness.worktreeID]?.windowedPaneIDs = [harness.paneID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
      $0.wakeRequestedTabs = [harness.selectedTab]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = [harness.selectedTab]
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    await harness.clock.advance(by: LayoutFeature.wakeDeferral)
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.wakingTabs = []
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 2
      $0.wakeRequestedTabs = []
    }
    #expect(harness.selectedContent.renderer != nil)
    // Drain the armed timer so the store finishes clean.
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func zoomedPaneHidesTheOtherPanesSelectedTab() async throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let worktreeID = Worktree.ID("/tmp/zoom")
    let paneA = PaneID()
    let paneB = PaneID()
    let tabA = TabID()
    let tabB = TabID()
    let contentA = HibernatableContent(id: ContentID())
    let contentB = HibernatableContent(id: ContentID())
    let runtime = ContentRuntime()
    _ = runtime.provision(contentA, at: .fallback)
    _ = runtime.provision(contentB, at: .fallback)
    var tree = try SplitTree(view: paneA).inserting(view: paneB, at: paneA, direction: .right)
    tree = tree.settingZoomed(try #require(tree.find(id: paneA.rawValue)))
    let layout = PaneLayout(
      tree: tree,
      panes: [
        Pane(
          id: paneA,
          tabs: [
            TabItem(
              id: tabA,
              title: "A",
              content: ContentSnapshot(
                id: contentA.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabA
        ),
        Pane(
          id: paneB,
          tabs: [
            TabItem(
              id: tabB,
              title: "B",
              content: ContentSnapshot(
                id: contentB.id,
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabB
        ),
      ],
      focusedPaneID: paneA
    )
    let clock = TestClock()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    await store.send(.selectedWorktreeChanged(worktreeID)) {
      $0.selectedWorktreeID = worktreeID
      $0.recentWorktreeIDs = [worktreeID]
      // Pane B sits behind the zoom, so its selection is hidden and arms.
      $0.hibernationArmedTabs = [tabB]
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await store.send(.hibernationPolicyChanged) {
      $0.hibernationArmedTabs = []
    }
  }

  @Test(.dependencies) func detachLayoutCancelsArmedGraceTimers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    // Selecting another worktree hides both tabs; both arm.
    await harness.store.send(.selectedWorktreeChanged(Worktree.ID("/tmp/other"))) {
      $0.selectedWorktreeID = Worktree.ID("/tmp/other")
      $0.recentWorktreeIDs = [Worktree.ID("/tmp/other")]
      $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
    }
    await harness.store.send(.detachLayout(worktreeID: harness.worktreeID)) {
      $0.layouts = []
      $0.hibernationArmedTabs = []
    }
    // Cancelled timers must never fire.
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  // MARK: - Recency and memory pressure.

  private struct RecencyHarness {
    let store: TestStoreOf<TerminalsFeature>
    let clock: TestClock<Duration>
    let pressure: AsyncStream<Void>.Continuation
    let worktreeIDs: [Worktree.ID]
    let tabs: [TabID]
    let contents: [HibernatableContent]
  }

  /// `count` single-tab worktrees, every content live, nothing selected yet.
  private func makeRecencyHarness(count: Int) -> RecencyHarness {
    let runtime = ContentRuntime()
    var worktreeIDs: [Worktree.ID] = []
    var tabs: [TabID] = []
    var contents: [HibernatableContent] = []
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    for index in 0..<count {
      let worktreeID = Worktree.ID("/tmp/recency-\(index)")
      let tabID = TabID()
      let content = HibernatableContent(id: ContentID())
      _ = runtime.provision(content, at: .fallback)
      layouts.append(
        LayoutFeature.State(
          id: worktreeID,
          layout: Self.layout(paneID: PaneID(), tabID: tabID, contentID: content.id)
        )
      )
      worktreeIDs.append(worktreeID)
      tabs.append(tabID)
      contents.append(content)
    }
    let clock = TestClock()
    let pressure = AsyncStream<Void>.makeStream()
    let warnings = pressure.stream
    let store = TestStore(initialState: TerminalsFeature.State(layouts: layouts)) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[MemoryPressureClient.self] = MemoryPressureClient(warnings: { warnings })
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    return RecencyHarness(
      store: store,
      clock: clock,
      pressure: pressure.continuation,
      worktreeIDs: worktreeIDs,
      tabs: tabs,
      contents: contents
    )
  }

  @Test(.dependencies, arguments: [4, 256])
  func localLayoutReconciliationDoesNotReadUnrelatedRenderers(count: Int) async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: count)
    for content in harness.contents.dropFirst() { content.hibernate() }
    let selected = harness.worktreeIDs[0]
    await harness.store.send(.selectedWorktreeChanged(selected)) {
      $0.selectedWorktreeID = selected
      $0.recentWorktreeIDs = [selected]
    }
    let before = harness.contents.map(\.rendererReads)
    await harness.store.send(.layouts(.element(id: selected, action: .selectTab(id: harness.tabs[0]))))
    #expect(harness.contents.dropFirst().map(\.rendererReads) == Array(before.dropFirst()))
    await harness.store.send(.hibernationPolicyChanged)
    #expect(harness.contents.dropFirst().map(\.rendererReads) == before.dropFirst().map { $0 + 1 })
    await harness.store.finish()
  }

  @Test(.dependencies) func switchingWorktreesDoesNotReadUnrelatedHibernatedRenderers() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 4)
    for content in harness.contents.dropFirst(2) { content.hibernate() }
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[0])) {
      $0.selectedWorktreeID = harness.worktreeIDs[0]
      $0.recentWorktreeIDs = [harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = [harness.tabs[1]]
    }
    let before = harness.contents.dropFirst(2).map(\.rendererReads)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[1])) {
      $0.selectedWorktreeID = harness.worktreeIDs[1]
      $0.recentWorktreeIDs = [harness.worktreeIDs[1], harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = []
    }
    #expect(harness.contents.dropFirst(2).map(\.rendererReads) == before)
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.finish()
  }

  @Test(.dependencies, arguments: [false, true])
  func removingAWorktreeOrItsLastTabPreservesUnrelatedTimers(detach: Bool) async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 3)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[0])) {
      $0.selectedWorktreeID = harness.worktreeIDs[0]
      $0.recentWorktreeIDs = [harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = Set(harness.tabs.dropFirst())
    }
    let removed = harness.worktreeIDs[1]
    let action: TerminalsFeature.Action =
      detach
      ? .detachLayout(worktreeID: removed)
      : .layouts(.element(id: removed, action: .closeTab(id: harness.tabs[1])))
    await harness.store.send(action) {
      if detach { $0.layouts.remove(id: removed) } else { $0.layouts[id: removed]?.layout = PaneLayout() }
      $0.hibernationArmedTabs = [harness.tabs[2]]
    }
    if !detach { await harness.store.receive(\.layouts) }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) { $0.hibernationArmedTabs = [] }
    await harness.store.receive(\.layouts) { $0.layouts[id: harness.worktreeIDs[2]]?.renderEpoch = 1 }
    #expect(harness.contents[2].renderer == nil)
    await harness.store.finish()
  }

  @Test(.dependencies, arguments: [false, true])
  func pressureLeavesNoTimersAfterHibernatingTwoTabsInOneLayout(parked: Bool) async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    let other = Worktree.ID("/tmp/other")
    if parked {
      await harness.store.send(.hibernationPolicyChanged) {
        $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
      }
    } else {
      await harness.store.send(.selectedWorktreeChanged(other)) {
        $0.selectedWorktreeID = other
        $0.recentWorktreeIDs = [other]
        $0.hibernationArmedTabs = [harness.selectedTab, harness.hiddenTab]
      }
    }
    await harness.store.send(.memoryPressureWarning) { $0.hibernationArmedTabs = [] }
    // A renderer-only completion must not re-arm its still-live sibling
    // while that sibling's pressure action is queued.
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 2
      $0.hibernationArmedTabs = []
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.selectedContent.renderer == nil)
    #expect(harness.hiddenContent.renderer == nil)
    await harness.store.finish()
  }

  @Test(.dependencies) func pressureRearmsIneligibleRetainedContentWhenOtherWorktreesHibernate() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 3)
    var recents: [Worktree.ID] = []
    for (index, id) in harness.worktreeIDs.enumerated() {
      recents.insert(id, at: 0)
      let expected = recents
      await harness.store.send(.selectedWorktreeChanged(id)) {
        $0.selectedWorktreeID = id
        $0.recentWorktreeIDs = expected
        $0.hibernationArmedTabs = Set(harness.tabs.dropFirst(index + 1))
      }
    }
    harness.contents[0].claimsHibernation = false
    await harness.store.send(.memoryPressureWarning) {
      $0.recentWorktreeIDs = [harness.worktreeIDs[2]]
      $0.hibernationArmedTabs = [harness.tabs[0]]
    }
    await harness.store.receive(\.layouts) { $0.layouts[id: harness.worktreeIDs[1]]?.renderEpoch = 1 }
    harness.contents[0].claimsHibernation = true
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) { $0.hibernationArmedTabs = [] }
    await harness.store.receive(\.layouts) { $0.layouts[id: harness.worktreeIDs[0]]?.renderEpoch = 1 }
    #expect(harness.contents[0].renderer == nil)
    await harness.store.finish()
  }

  @Test(.dependencies, arguments: [false, true])
  func crossingTheTreeBackstopArmsTheEvictedWorktree(cancelImmediately: Bool) async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: ContentRetentionPolicy.maximumWorktrees + 1)
    for content in harness.contents { content.estimatedRetentionBytes = 1 }
    for (index, id) in harness.worktreeIDs.enumerated() {
      let visited = Array(harness.worktreeIDs.prefix(index + 1).reversed())
      let retained = Array(visited.prefix(ContentRetentionPolicy.maximumWorktrees))
      let armed = Set(
        harness.tabs.enumerated().compactMap { offset, tab in
          retained.contains(harness.worktreeIDs[offset]) ? nil : tab
        })
      await harness.store.send(.selectedWorktreeChanged(id)) {
        $0.selectedWorktreeID = id
        $0.recentWorktreeIDs = retained
        $0.hibernationArmedTabs = armed
      }
    }
    #expect(harness.store.state.hibernationArmedTabs == [harness.tabs[0]])
    if cancelImmediately {
      $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
      await harness.store.send(.hibernationPolicyChanged) { $0.hibernationArmedTabs = [] }
      await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
      #expect(harness.contents.allSatisfy { $0.renderer != nil })
    } else {
      await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
      await harness.store.receive(\.hibernationGraceElapsed) { $0.hibernationArmedTabs = [] }
      await harness.store.receive(\.layouts) { $0.layouts[id: harness.worktreeIDs[0]]?.renderEpoch = 1 }
      #expect(harness.contents[0].renderer == nil)
    }
    await harness.store.finish()
  }

  @Test(.dependencies) func localCostChangeReconcilesOtherEvictedWorktrees() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 3)
    for (index, id) in harness.worktreeIDs.enumerated() {
      await harness.store.send(.selectedWorktreeChanged(id)) {
        $0.selectedWorktreeID = id
        $0.recentWorktreeIDs = Array(harness.worktreeIDs.prefix(index + 1).reversed())
        $0.hibernationArmedTabs = Set(harness.tabs.dropFirst(index + 1))
      }
    }
    harness.contents[2].estimatedRetentionBytes = ContentRetentionPolicy.testValue.budgetBytes
    await harness.store.send(.layouts(.element(id: harness.worktreeIDs[2], action: .selectTab(id: harness.tabs[2])))) {
      $0.recentWorktreeIDs = [harness.worktreeIDs[2]]
      $0.hibernationArmedTabs = Set(harness.tabs.prefix(2))
    }
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged) { $0.hibernationArmedTabs = [] }
    await harness.store.finish()
  }

  @Test(.dependencies) func cheapWorktreesRemainRetainedBeyondEightSelections() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 12)
    for content in harness.contents { content.estimatedRetentionBytes = 1 }
    var recents: [Worktree.ID] = []
    for (index, id) in harness.worktreeIDs.enumerated() {
      recents.insert(id, at: 0)
      let expected = recents
      let neverSelected = Set(harness.tabs.dropFirst(index + 1))
      await harness.store.send(.selectedWorktreeChanged(id)) {
        $0.selectedWorktreeID = id
        $0.recentWorktreeIDs = expected
        $0.hibernationArmedTabs = neverSelected
      }
    }
    #expect(harness.store.state.recentWorktreeIDs.count == 12)
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.contents.allSatisfy { $0.renderer != nil })
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    await harness.store.send(.hibernationPolicyChanged)
    await harness.store.finish()
  }

  @Test(.dependencies) func recentlySelectedWorktreesSurviveTheGraceWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 2)
    // The never-selected worktree arms straight away; recency covers nothing yet.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[0])) {
      $0.selectedWorktreeID = harness.worktreeIDs[0]
      $0.recentWorktreeIDs = [harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = [harness.tabs[1]]
    }
    // Switching away leaves the first worktree inside the recency window, so
    // its visible tab never arms and the clock has nothing to fire.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[1])) {
      $0.selectedWorktreeID = harness.worktreeIDs[1]
      $0.recentWorktreeIDs = [harness.worktreeIDs[1], harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = []
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    #expect(harness.contents.allSatisfy { $0.renderer != nil })
    await harness.store.finish()
  }

  @Test(.dependencies) func worktreesEvictedFromTheRecencyWindowHibernate() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let count = 9
    let harness = makeRecencyHarness(count: count)
    // Every worktree past the first starts unseen, so selecting the first arms
    // all of them; each later selection cancels its own timer.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[0])) {
      $0.selectedWorktreeID = harness.worktreeIDs[0]
      $0.recentWorktreeIDs = [harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = Set(harness.tabs.dropFirst())
    }
    for index in 1..<(count - 1) {
      await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[index])) {
        $0.selectedWorktreeID = harness.worktreeIDs[index]
        $0.recentWorktreeIDs = Array(harness.worktreeIDs[0...index].reversed())
        $0.hibernationArmedTabs = Set(harness.tabs.dropFirst(index + 1))
      }
    }
    // The last selection pushes the first worktree out of the window; it is the
    // only one the clock can now reach.
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[count - 1])) {
      $0.selectedWorktreeID = harness.worktreeIDs[count - 1]
      $0.recentWorktreeIDs = Array(harness.worktreeIDs[1...].reversed())
      $0.hibernationArmedTabs = [harness.tabs[0]]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)
    await harness.store.receive(\.hibernationGraceElapsed) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeIDs[0]]?.renderEpoch = 1
    }
    #expect(harness.contents[0].renderer == nil)
    #expect(harness.contents.dropFirst().allSatisfy { $0.renderer != nil })
  }

  @Test(.dependencies) func memoryPressureHibernatesHiddenTabsWithoutWaitingOutTheWindow() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHibernationHarness()
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
      $0.hibernationArmedTabs = [harness.hiddenTab]
    }
    await harness.store.send(.task)
    harness.pressure.yield()
    await harness.store.receive(\.memoryPressureWarning) {
      $0.hibernationArmedTabs = []
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeID]?.renderEpoch = 1
    }
    #expect(harness.hiddenContent.renderer == nil)
    #expect(harness.selectedContent.renderer != nil)
    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test(.dependencies) func memoryPressureCollapsesTheRecencyBudgetToTheSelection() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeRecencyHarness(count: 2)
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[0])) {
      $0.selectedWorktreeID = harness.worktreeIDs[0]
      $0.recentWorktreeIDs = [harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = [harness.tabs[1]]
    }
    await harness.store.send(.selectedWorktreeChanged(harness.worktreeIDs[1])) {
      $0.selectedWorktreeID = harness.worktreeIDs[1]
      $0.recentWorktreeIDs = [harness.worktreeIDs[1], harness.worktreeIDs[0]]
      $0.hibernationArmedTabs = []
    }
    await harness.store.send(.task)
    harness.pressure.yield()
    // Recency is the first thing pressure spends: the retained worktree loses
    // its cover and hibernates in the same turn.
    await harness.store.receive(\.memoryPressureWarning) {
      $0.recentWorktreeIDs = [harness.worktreeIDs[1]]
    }
    await harness.store.receive(\.layouts) {
      $0.layouts[id: harness.worktreeIDs[0]]?.renderEpoch = 1
    }
    #expect(harness.contents[0].renderer == nil)
    #expect(harness.contents[1].renderer != nil)
    harness.pressure.finish()
    await harness.store.finish()
  }

  @Test func layoutsHydrationServesConsistentRecordsOnly() async {
    let paneID = PaneID()
    let good = Self.layout(paneID: paneID, tabID: TabID(), contentID: ContentID())
    // A tree leaf with no matching pane fails the consistency gate.
    let bad = PaneLayout(tree: SplitTree(view: PaneID()), panes: [], focusedPaneID: nil)
    let file = LayoutsFile(worktrees: [
      "/tmp/good": LayoutRecord(layout: good),
      "/tmp/bad": LayoutRecord(layout: bad),
    ])
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/good"), layout: good)]
    }
  }

  @Test func layoutsHydrationDropsCrossWorktreeIDCollisions() async {
    let sharedContentID = ContentID()
    let first = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    // The second worktree reuses the same content id (pre-gate data); it would
    // collide in the globally keyed runtime, so only the first key hydrates.
    let second = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: sharedContentID)
    let file = LayoutsFile(worktrees: [
      "/tmp/a": LayoutRecord(layout: first),
      "/tmp/b": LayoutRecord(layout: second),
    ])
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/a"), layout: first)]
    }
  }

  @Test func layoutsHydrationNeverReplacesALiveLayout() async {
    let live = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let persisted = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let worktreeID = Worktree.ID("/tmp/repo")
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: live)])
    ) {
      TerminalsFeature()
    }
    await store.send(.layoutsHydrated(LayoutsFile(worktrees: ["/tmp/repo": LayoutRecord(layout: persisted)])))
  }

  @Test func newerSchemaServesRecordsButMarksThemReadOnly() async {
    let good = Self.layout(paneID: PaneID(), tabID: TabID(), contentID: ContentID())
    let file = LayoutsFile(
      schemaVersion: LayoutsFile.currentSchemaVersion + 1,
      worktrees: ["/tmp/good": LayoutRecord(layout: good)]
    )
    let store = TestStore(initialState: TerminalsFeature.State()) { TerminalsFeature() }
    await store.send(.layoutsHydrated(file)) {
      $0.layoutsAreReadOnly = true
      $0.layouts = [LayoutFeature.State(id: Worktree.ID("/tmp/good"), layout: good)]
    }
  }
}
