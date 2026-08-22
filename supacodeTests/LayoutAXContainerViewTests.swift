import ComposableArchitecture
import Testing

@testable import supacode

/// Locks the gate that keeps the nested hosting view's root from being
/// rewritten on every outer body pass: a member that stops reaching the
/// comparison would freeze the hosted tree with no compile error.
@MainActor
struct LayoutAXContainerViewTests {
  private func makeStore() -> StoreOf<LayoutFeature> {
    Store(initialState: LayoutFeature.State(id: Worktree.ID("/tmp/ax-container"), layout: PaneLayout())) {
      LayoutFeature()
    }
  }

  @Test func unchangedInputsLeaveTheHostedRootAlone() {
    let store = makeStore()
    let inputs = PaneTreeInputs(
      store: store,
      renderContext: PaneRenderContext(runtime: ContentRuntime(), dragModel: PaneTabDragModel()))
    let container = LayoutAXContainerView()

    container.update(inputs: inputs, panes: [])
    #expect(container.hostedRootWrites == 1)

    container.update(inputs: inputs, panes: [])
    #expect(container.hostedRootWrites == 1)
  }

  @Test func aChangedRenderContextRewritesTheHostedRoot() {
    let store = makeStore()
    let runtime = ContentRuntime()
    let dragModel = PaneTabDragModel()
    let container = LayoutAXContainerView()

    container.update(
      inputs: PaneTreeInputs(
        store: store,
        renderContext: PaneRenderContext(runtime: runtime, dragModel: dragModel)),
      panes: [])
    #expect(container.hostedRootWrites == 1)

    // `isLifecycleBusy` reaches the tab strip only through the render context,
    // and nothing about it is observable, so the gate is its only route in.
    container.update(
      inputs: PaneTreeInputs(
        store: store,
        renderContext: PaneRenderContext(runtime: runtime, isLifecycleBusy: true, dragModel: dragModel)),
      panes: [])
    #expect(container.hostedRootWrites == 2)
  }
}
