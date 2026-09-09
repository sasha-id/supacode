import AppKit
import ComposableArchitecture
import ConcurrencyExtras
import SwiftUI
import Testing

@testable import supacode

/// Locks the gate that keeps the nested hosting view's root from being
/// rewritten on every outer body pass: a member that stops reaching the
/// comparison would freeze the hosted tree with no compile error.
@MainActor
struct LayoutAXContainerViewTests {
  @Test func replacingContentWithTheSameIDRemountsWithoutAnEpochOrRootRewrite() async throws {
    let runtime = ContentRuntime()
    let first = RendererContent()
    let container = NSHostingView(rootView: PaneRendererView(contentID: first.id, runtime: runtime))
    container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(
      contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.contentView = container
    defer { window.contentView = nil }
    container.layoutSubtreeIfNeeded()
    #expect(runtime.provision(first, at: .fallback))
    await Task.megaYield()
    container.layoutSubtreeIfNeeded()
    let firstRenderer = try #require(first.renderer)
    #expect(firstRenderer.isDescendant(of: container))

    runtime.remove(first.id, tombstone: false)
    let replacement = RendererContent(id: first.id)
    #expect(runtime.provision(replacement, at: .fallback))
    await Task.megaYield()
    container.layoutSubtreeIfNeeded()
    let replacementRenderer = try #require(replacement.renderer)
    #expect(replacementRenderer.isDescendant(of: container))
    #expect(!firstRenderer.isDescendant(of: container))
    runtime.hibernate(replacement.id)
    runtime.startSession(replacement.id, at: .fallback)
    await Task.megaYield()
    container.layoutSubtreeIfNeeded()
    let rewokenRenderer = try #require(replacement.renderer)
    #expect(rewokenRenderer.isDescendant(of: container))
    #expect(!replacementRenderer.isDescendant(of: container))
  }

  private final class RendererContent: supacode.TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private(set) var renderer: NSView?

    init(id: ContentID = ContentID()) { self.id = id }
    func startSession(at geometry: ContentGeometry) { renderer = NSView() }
    func hibernate() { renderer = nil }
    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(TerminalContentState(workingDirectory: nil)))
    }
  }

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
