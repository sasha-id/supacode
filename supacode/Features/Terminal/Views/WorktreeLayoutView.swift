import AppKit
import ComposableArchitecture
import SwiftUI

/// One worktree's terminal area on the layout engine: the pane tree, its
/// window-activity sync, and terminal auto-focus. The close-confirmation alert
/// presents outside this tree, from `WorktreeLayoutAlertPresenter`.
struct WorktreeLayoutView: View {
  let worktree: Worktree
  let manager: WorktreeTerminalManager
  let terminalsStore: StoreOf<TerminalsFeature>
  let runtime: ContentRuntime
  let forceAutoFocus: Bool
  /// Whether this worktree is the one on screen. Deselected trees stay mounted
  /// so a switch never reparents a surface, so everything that reaches out of
  /// the tree — focus claims — has to gate on this.
  var isSelected = true
  var isLifecycleBusy = false
  @State private var windowActivity = WindowActivityState.inactive
  @State private var windowActivityReader = WindowActivityReader()
  // Reading `\.colorScheme` invalidates this body when the window appearance
  // flips (terminal-driven Light/Dark), so the unfocused-split overlay retints.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    // Re-read config-derived colors on every Ghostty config reload.
    let _ = manager.configGeneration
    let _ = colorScheme
    let selectedContentID = selectedContentID
    Group {
      // An empty layout renders the hint instead of an empty pane tree.
      if let layoutStore = terminalsStore.scope(
        state: \.layouts[id: worktree.id],
        action: \.layouts[id: worktree.id]
      ), !layoutStore.layout.panes.isEmpty {
        LayoutContentView(
          store: layoutStore,
          runtime: runtime,
          dividerColor: manager.splitDividerColor(),
          unfocusedOverlay: manager.unfocusedSplitOverlay(),
          services: manager.renderServices(for: worktree.id),
          isLifecycleBusy: isLifecycleBusy
        )
      } else {
        // No strip is mounted here, so the default "+" hint would point at a
        // control that is not on screen.
        EmptyTerminalPaneView(
          message: "No terminals open",
          hint: Text("Press \(Text("⌘T").bold()) to open a new terminal.")
        )
      }
    }
    .background(
      WindowFocusObserverView(reader: windowActivityReader) { activity in
        windowActivity = activity
        host?.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
      }
    )
    .onAppear {
      if isSelected, shouldAutoFocusTerminal {
        host?.focusSelectedTab()
      }
      syncResolvedWindowActivity()
    }
    // Catch a focus intent that lands after the first appearance.
    .onChange(of: forceAutoFocus) { _, focus in
      if focus, isSelected { host?.focusSelectedTab() }
    }
    .onChange(of: selectedContentID) {
      if isSelected, shouldAutoFocusTerminal {
        host?.focusSelectedTab()
      }
      syncResolvedWindowActivity()
    }
  }

  private var host: WorktreeContentHost? {
    manager.hostIfExists(for: worktree.id)
  }

  /// The focused pane's selected content; drives the auto-focus handoff when
  /// selection moves (Cmd+T, tab click, deeplink jump).
  private var selectedContentID: UUID? {
    guard let layout = terminalsStore.layouts[id: worktree.id]?.layout,
      let focused = layout.focusedPaneID
    else { return nil }
    return layout.panes[id: focused]?.selectedTab?.content.id.rawValue
  }

  private var shouldAutoFocusTerminal: Bool {
    if forceAutoFocus {
      return true
    }
    guard let responder = NSApp.keyWindow?.firstResponder else { return true }
    return !(responder is NSTableView) && !(responder is NSOutlineView)
  }

  private func syncResolvedWindowActivity() {
    // The observed window is authoritative; `NSApp.keyWindow` can be another
    // window entirely (e.g. the command palette panel).
    let activity = windowActivityReader.current ?? windowActivity
    host?.syncFocus(windowIsKey: activity.isKeyWindow, windowIsVisible: activity.isVisible)
  }
}

/// Binds one worktree's close-confirmation alert. Mounted alongside the
/// terminal stack rather than inside it: the stack hosts each worktree's tree
/// in its own `NSHostingView`, and only the selected worktree's alert may
/// present over the window.
struct WorktreeLayoutAlertPresenter: View {
  @Bindable var store: StoreOf<LayoutFeature>

  /// Alerts raised from a windowed pane present in that pane's window; this
  /// presenter owns the rest.
  private var presentsAlert: Bool {
    store.alertPaneID.map { !store.windowedPaneIDs.contains($0) } ?? true
  }

  var body: some View {
    if presentsAlert {
      Color.clear.alert($store.scope(state: \.alert, action: \.alert))
    }
  }
}
