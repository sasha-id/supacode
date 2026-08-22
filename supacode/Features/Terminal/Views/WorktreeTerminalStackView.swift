import AppKit
import ComposableArchitecture
import SwiftUI

/// Everything one worktree's terminal tree renders from, as one value.
///
/// `WorktreeLayoutView` holds `@State` and so cannot be `Equatable` itself;
/// this is its whole input surface, which lets the stack rewrite a hosted root
/// only when something the tree actually reads moved.
struct WorktreeTerminalInputs: Equatable {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let terminalsStore: StoreOf<TerminalsFeature>
  let runtime: ContentRuntime
  var isSelected = true
  var forceAutoFocus = false
  var isLifecycleBusy = false
  let ghosttyShortcuts: GhosttyShortcutManager
  let commandKeyObserver: CommandKeyObserver

  func deselected() -> Self {
    var copy = self
    copy.isSelected = false
    copy.forceAutoFocus = false
    return copy
  }
}

/// The hosted root of one worktree's terminal tree. Environment objects do not
/// cross a hosting boundary, so the ones the pane tree needs are re-injected.
struct WorktreeTerminalRoot: View {
  let inputs: WorktreeTerminalInputs

  var body: some View {
    WorktreeLayoutView(
      worktree: inputs.worktree,
      manager: inputs.manager,
      terminalsStore: inputs.terminalsStore,
      runtime: inputs.runtime,
      forceAutoFocus: inputs.forceAutoFocus,
      isSelected: inputs.isSelected,
      isLifecycleBusy: inputs.isLifecycleBusy
    )
    .environment(inputs.ghosttyShortcuts)
    .environment(inputs.commandKeyObserver)
  }
}

/// Mounts the selected worktree's terminal tree and keeps the recently visited
/// ones mounted but hidden, so selecting another worktree flips visibility
/// instead of tearing the hosting chain down and reparenting live surfaces.
struct WorktreeTerminalStack: NSViewRepresentable {
  let inputs: WorktreeTerminalInputs

  func makeNSView(context: Context) -> WorktreeTerminalStackView {
    WorktreeTerminalStackView()
  }

  func updateNSView(_ nsView: WorktreeTerminalStackView, context: Context) {
    nsView.select(inputs)
  }
}

@MainActor
final class WorktreeTerminalStackView: NSView {
  /// Trees kept mounted past deselection, so the common back-and-forth costs
  /// nothing. Bounds the resident view trees; switching past this many
  /// worktrees only pays the remount that every switch used to pay.
  static let mountLimit = 8

  private var hosted: [Worktree.ID: NSHostingView<WorktreeTerminalRoot>] = [:]
  /// Mounted worktrees, least recently selected first.
  private var mountOrder: [Worktree.ID] = []
  /// Hosted-root writes since creation; the gate that suppresses them is
  /// otherwise unobservable from a test.
  private(set) var hostedRootWrites = 0
  private(set) var selectedWorktreeID: Worktree.ID?

  var mountedWorktreeIDs: [Worktree.ID] { mountOrder }

  /// The hosting view a worktree's tree lives in, for asserting that a switch
  /// left it in place.
  func hostedView(for worktreeID: Worktree.ID) -> NSView? {
    hosted[worktreeID]
  }

  func select(_ inputs: WorktreeTerminalInputs) {
    let worktreeID = inputs.worktree.id
    let selectionMoved = selectedWorktreeID != worktreeID
    // Read before anything hides: AppKit leaves first responder inside a hidden
    // subtree, so whatever the outgoing tree holds — a surface, the find bar's
    // field, a rename field — has to be handed over by hand.
    let outgoing = selectionMoved ? selectedWorktreeID.flatMap { hosted[$0] } : nil
    let outgoingHoldsKeyboard = outgoing.map { Self.containsFirstResponder($0) } ?? false
    if let previousID = selectedWorktreeID, selectionMoved {
      deselect(previousID)
    }
    let hosting = hosted[worktreeID] ?? mount(worktreeID: worktreeID, inputs: inputs)
    write(inputs, to: hosting)
    selectedWorktreeID = worktreeID
    mountOrder.removeAll { $0 == worktreeID }
    mountOrder.append(worktreeID)
    for (id, view) in hosted {
      let shouldHide = id != worktreeID
      if view.isHidden != shouldHide {
        view.isHidden = shouldHide
      }
    }
    if selectionMoved {
      // Hiding a tree drops its holes from the window tint without moving any
      // region, so nothing else would mark the mask dirty.
      WindowTintMaskRegistry.regionVisibilityDidChange(in: self)
    }
    if let outgoing, outgoingHoldsKeyboard {
      handOverFirstResponder(from: outgoing, to: worktreeID, manager: inputs.manager)
    }
    evictBeyondMountLimit()
  }

  /// Hands the keyboard to the incoming worktree's focused terminal, then parks
  /// anything the outgoing tree still holds so a hidden tree never keeps first
  /// responder. A hibernated target latches the claim and lands it through
  /// `applySurfaceActivity` instead.
  private func handOverFirstResponder(
    from outgoing: NSView,
    to worktreeID: Worktree.ID,
    manager: WorktreeTerminalManager
  ) {
    manager.hostIfExists(for: worktreeID)?.focusSelectedTab()
    guard Self.containsFirstResponder(outgoing) else { return }
    outgoing.window?.makeFirstResponder(nil)
  }

  /// Whether the window's first responder lives inside `view`. An editing text
  /// field answers through its field editor, which is mounted inside it.
  static func containsFirstResponder(_ view: NSView) -> Bool {
    guard let responder = view.window?.firstResponder as? NSView else { return false }
    return responder.isDescendant(of: view)
  }

  /// Republishes the outgoing tree as deselected: it stays mounted, so nothing
  /// else tells it to stop claiming terminal focus or window activity.
  private func deselect(_ worktreeID: Worktree.ID) {
    guard let hosting = hosted[worktreeID] else { return }
    write(hosting.rootView.inputs.deselected(), to: hosting)
  }

  private func write(_ inputs: WorktreeTerminalInputs, to hosting: NSHostingView<WorktreeTerminalRoot>) {
    // Every assignment re-renders the whole tree behind the AppKit boundary,
    // so an unchanged root is left alone; the hosted body still re-runs on its
    // own observation of the store and the shared settings file.
    guard hosting.rootView.inputs != inputs else { return }
    hosting.rootView = WorktreeTerminalRoot(inputs: inputs)
    hostedRootWrites += 1
  }

  private func mount(
    worktreeID: Worktree.ID,
    inputs: WorktreeTerminalInputs
  ) -> NSHostingView<WorktreeTerminalRoot> {
    let hosting = NSHostingView(rootView: WorktreeTerminalRoot(inputs: inputs))
    hostedRootWrites += 1
    // The window uses a full-size content view; without this the hosted tree
    // insets below the titlebar wherever the stack overlaps it.
    hosting.safeAreaRegions = []
    hosting.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.topAnchor.constraint(equalTo: topAnchor),
      hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    hosted[worktreeID] = hosting
    return hosting
  }

  private func evictBeyondMountLimit() {
    while mountOrder.count > Self.mountLimit {
      let evicted = mountOrder.removeFirst()
      hosted.removeValue(forKey: evicted)?.removeFromSuperview()
    }
  }
}
