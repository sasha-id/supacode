import Foundation

/// The worktree-scoped lookups a pane tree needs, on one long-lived object.
///
/// These used to be closures minted inside `WorktreeLayoutView.body`, which
/// made `PaneRenderContext` — and every pane view carrying it — compare
/// unequal on every pass, so SwiftUI could never skip an unchanged pane and
/// the hosted pane tree was rewritten each time. The manager vends one
/// instance per worktree, so the reference is a stable equality token.
@MainActor
final class PaneRenderServices {
  private let worktreeID: Worktree.ID
  private weak var manager: WorktreeTerminalManager?

  init(worktreeID: Worktree.ID, manager: WorktreeTerminalManager) {
    self.worktreeID = worktreeID
    self.manager = manager
  }

  /// The observable unseen-notification counter for a content id.
  func surfaceState(_ surfaceID: UUID) -> WorktreeSurfaceState? {
    manager?.hostIfExists(for: worktreeID)?.surfaceStates[surfaceID]
  }

  /// Brings a windowed pane's window to the front.
  func showWindowedPane(_ paneID: PaneID) {
    manager?.paneWindows.orderFront(worktreeID: worktreeID, paneID: paneID)
  }
}

/// Identity equality, so the views carrying this reference stay diffable.
extension PaneRenderServices: Equatable {
  nonisolated static func == (lhs: PaneRenderServices, rhs: PaneRenderServices) -> Bool {
    lhs === rhs
  }
}
