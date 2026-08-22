import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Locks the classification that decides how much app-shell work a layout
/// action pays for: only `.structural` actions re-derive content lifecycle,
/// surface activity, pane windows, and the sidebar projection.
@MainActor
struct LayoutChangeScopeTests {
  private struct Harness {
    let store: TestStoreOf<TerminalsFeature>
    let scopes: LockIsolated<[LayoutChangeScope]>
    let worktreeID: Worktree.ID
    let paneID: PaneID
    let firstTab: TabID
    let secondTab: TabID
  }

  private func makeHarness() -> Harness {
    let worktreeID = Worktree.ID("/tmp/scope")
    let paneID = PaneID()
    let firstTab = TabID()
    let secondTab = TabID()
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: firstTab,
              title: "One",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
            TabItem(
              id: secondTab,
              title: "Two",
              content: ContentSnapshot(
                id: ContentID(),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            ),
          ],
          selectedTabID: firstTab
        )
      ],
      focusedPaneID: paneID
    )
    let scopes = LockIsolated<[LayoutChangeScope]>([])
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.contentRuntime = ContentRuntime()
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
      $0[LayoutChangeObserver.self] = LayoutChangeObserver(
        layoutChanged: { _, scope in scopes.withValue { $0.append(scope) } }
      )
    }
    return Harness(
      store: store,
      scopes: scopes,
      worktreeID: worktreeID,
      paneID: paneID,
      firstTab: firstTab,
      secondTab: secondTab
    )
  }

  @Test func frameRateActionsClassifyAsBookkeeping() {
    #expect(TerminalsFeature.changeScope(.endTabRename) == .bookkeeping)
    #expect(TerminalsFeature.changeScope(.beginTabRename(id: TabID())) == .bookkeeping)
    #expect(
      TerminalsFeature.changeScope(.resizePane(node: .leaf(view: PaneID()), ratio: 0.4)) == .bookkeeping
    )
    // A teardown title commit moves no surface; it only has to re-arm the save.
    #expect(
      TerminalsFeature.changeScope(.runtime(.titleCommitted(id: ContentID(), title: "zsh"))) == .bookkeeping
    )
  }

  @Test func topologyVisibilityAndFocusActionsClassifyAsStructural() {
    let tabID = TabID()
    let paneID = PaneID()
    #expect(TerminalsFeature.changeScope(.selectTab(id: tabID)) == .structural)
    #expect(TerminalsFeature.changeScope(.closeTab(id: tabID)) == .structural)
    #expect(TerminalsFeature.changeScope(.closePane(id: paneID)) == .structural)
    #expect(TerminalsFeature.changeScope(.toggleZoom(paneID: paneID)) == .structural)
    #expect(TerminalsFeature.changeScope(.focusPane(.pane(paneID))) == .structural)
    #expect(TerminalsFeature.changeScope(.hibernateTab(id: tabID)) == .structural)
    #expect(TerminalsFeature.changeScope(.wakeTab(id: tabID)) == .structural)
    #expect(TerminalsFeature.changeScope(.enterWindowMode(paneID: paneID)) == .structural)
    #expect(TerminalsFeature.changeScope(.equalizePanes) == .structural)
  }

  @Test(.dependencies) func observerReceivesTheActionsScope() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = false }
    let harness = makeHarness()
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .beginTabRename(id: harness.firstTab)))
    ) {
      $0.layouts[id: harness.worktreeID]?.editingTabID = harness.firstTab
    }
    await harness.store.send(
      .layouts(.element(id: harness.worktreeID, action: .selectTab(id: harness.secondTab)))
    ) {
      $0.layouts[id: harness.worktreeID]?.layout.panes[id: harness.paneID]?.selectedTabID = harness.secondTab
    }
    await harness.store.finish()

    #expect(harness.scopes.value == [.bookkeeping, .structural])
  }
}
