import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct TerminalsFeatureTests {
  /// Minimal live content whose renderer and eligibility the tests control.
  @MainActor
  private final class HibernatableContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    /// Eligibility knob for the fire-time re-arm path.
    var claimsHibernation = true
    private(set) var startCalls = 0
    private var view: NSView?
    private let state: TerminalContentState

    init(id: ContentID, state: TerminalContentState = TerminalContentState(workingDirectory: nil)) {
      self.id = id
      self.state = state
    }

    var renderer: NSView? { view }
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
    let count = TerminalsFeature.liveWorktreeLimit + 1
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
