import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

/// Close paths must land the new layout in the action that asked for it, with
/// content teardown and the async session kill trailing behind it.
@MainActor
struct LayoutFeatureCloseOrderingTests {
  // MARK: - Mocks.

  @MainActor
  private final class MockTabContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private(set) var tearDownCalls = 0
    private let initialState: TerminalContentState
    private var view: NSView?

    init(id: ContentID, initialState: TerminalContentState) {
      self.id = id
      self.initialState = initialState
    }

    var renderer: NSView? { view }

    func startSession(at geometry: ContentGeometry) {
      guard view == nil else { return }
      view = NSView()
    }

    func hibernate() {
      view = nil
    }

    func tearDown() {
      tearDownCalls += 1
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(initialState))
    }
  }

  @MainActor
  private final class ContentRecorder {
    private(set) var contents: [ContentID: MockTabContent] = [:]

    func make(_ request: ContentRequest) -> any TabContent {
      var state = TerminalContentState(workingDirectory: nil)
      if case .terminal(let terminal) = request.content {
        state = terminal
      }
      let content = MockTabContent(id: request.contentID, initialState: state)
      contents[request.contentID] = content
      return content
    }
  }

  // MARK: - Helpers.

  private static let worktreeID = WorktreeID("/tmp/layout-feature-close-ordering")
  private static let seedState = TerminalContentState(workingDirectory: "/tmp/layout-feature-close-ordering")

  private struct Harness {
    let store: TestStoreOf<LayoutFeature>
    let runtime: ContentRuntime
    let recorder: ContentRecorder
    let killed: LockIsolated<[ContentID]>
    let paneID: PaneID
    let tabID: TabID
    let contentID: ContentID
  }

  private static func spec(tabID: TabID, contentID: ContentID, title: String) -> NewTabSpec {
    NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: title,
      content: .terminal(seedState),
      geometry: .fallback,
      select: true
    )
  }

  private static func tab(id tabID: TabID, contentID: ContentID, title: String) -> TabItem {
    TabItem(id: tabID, title: title, content: ContentSnapshot(id: contentID, state: .terminal(seedState)))
  }

  /// One pane holding one tab, created through `newTab` so the runtime and the
  /// factory both saw the bootstrap.
  private func makeHarness() async -> Harness {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let recorder = ContentRecorder()
    let killed = LockIsolated<[ContentID]>([])
    let store = TestStore(
      initialState: LayoutFeature.State(
        id: Self.worktreeID,
        layout: PaneLayout(tree: SplitTree(view: paneID), panes: [Pane(id: paneID)], focusedPaneID: paneID)
      )
    ) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = runtime
      $0[SplitZoomPolicy.self] = SplitZoomPolicy(preservesZoomOnNavigation: { false })
      $0.layoutContentFactory = LayoutContentFactory(make: { request in recorder.make(request) })
      $0[ContentSessionKiller.self] = ContentSessionKiller(
        kill: { content, _ in killed.withValue { $0.append(content) } }
      )
    }
    await store.send(.newTab(inPane: paneID, spec: Self.spec(tabID: tabID, contentID: contentID, title: "One"))) {
      $0.layout.panes[id: paneID]?.tabs = [Self.tab(id: tabID, contentID: contentID, title: "One")]
      $0.layout.panes[id: paneID]?.selectedTabID = tabID
    }
    return Harness(
      store: store,
      runtime: runtime,
      recorder: recorder,
      killed: killed,
      paneID: paneID,
      tabID: tabID,
      contentID: contentID
    )
  }

  private struct SplitResult {
    let paneID: PaneID
    let tabID: TabID
    let contentID: ContentID
  }

  private func splitPane(_ harness: Harness, anchor: PaneID) async -> SplitResult {
    let newPaneID = PaneID(rawValue: UUID(0))
    let tabID = TabID()
    let contentID = ContentID()
    await harness.store.send(
      .splitPane(id: anchor, direction: .right, spec: Self.spec(tabID: tabID, contentID: contentID, title: "Split"))
    ) {
      $0.layout.tree = try $0.layout.tree.inserting(view: newPaneID, at: anchor, direction: .right)
      $0.layout.panes.append(
        Pane(id: newPaneID, tabs: [Self.tab(id: tabID, contentID: contentID, title: "Split")], selectedTabID: tabID)
      )
      $0.layout.focusedPaneID = newPaneID
    }
    return SplitResult(paneID: newPaneID, tabID: tabID, contentID: contentID)
  }

  // MARK: - Tests.

  @Test func closePaneCollapsesTheTreeInTheSameActionAndStillReaps() async throws {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    // The trailing closure is the whole state the action must land: the leaf
    // is out of the tree and the pane is gone by the time the send returns.
    await harness.store.send(.closePane(id: split.paneID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
    }
    let mock = try #require(harness.recorder.contents[split.contentID])
    // Detachment stays synchronous; only the libghostty free is deferred.
    #expect(mock.tearDownCalls == 1)
    #expect(harness.runtime.content(for: split.contentID) == nil)
    await harness.store.receive(.runtime(.killConfirmed(id: split.contentID)))
    #expect(harness.killed.value == [split.contentID])
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closePaneReapsEveryTabOfThePane() async throws {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    let extraTabID = TabID()
    let extraContentID = ContentID()
    await harness.store.send(
      .newTab(inPane: split.paneID, spec: Self.spec(tabID: extraTabID, contentID: extraContentID, title: "Extra"))
    ) {
      $0.layout.panes[id: split.paneID]?.tabs.append(
        Self.tab(id: extraTabID, contentID: extraContentID, title: "Extra")
      )
      $0.layout.panes[id: split.paneID]?.selectedTabID = extraTabID
    }
    // Kills are merged, so confirmation order is not defined; assert outcomes.
    harness.store.exhaustivity = .off
    await harness.store.send(.closePane(id: split.paneID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.recorder.contents[split.contentID]?.tearDownCalls == 1)
    #expect(harness.recorder.contents[extraContentID]?.tearDownCalls == 1)
    await harness.store.finish()
    #expect(Set(harness.killed.value) == [split.contentID, extraContentID])
    #expect(harness.killed.value.count == 2)
    #expect(harness.runtime.pendingKill.isEmpty)
    #expect(harness.store.state.layout.isConsistent)
  }

  @Test func closingAPanesLastTabCollapsesInTheSameActionAndStillReaps() async throws {
    let harness = await makeHarness()
    let split = await splitPane(harness, anchor: harness.paneID)
    await harness.store.send(.closeTab(id: split.tabID)) {
      $0.layout.tree = SplitTree(view: harness.paneID)
      $0.layout.panes.remove(id: split.paneID)
      $0.layout.focusedPaneID = harness.paneID
    }
    #expect(harness.recorder.contents[split.contentID]?.tearDownCalls == 1)
    #expect(harness.runtime.content(for: split.contentID) == nil)
    await harness.store.receive(.runtime(.killConfirmed(id: split.contentID)))
    #expect(harness.killed.value == [split.contentID])
    #expect(harness.store.state.layout.isConsistent)
  }
}
