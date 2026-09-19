import Dependencies
import Foundation

/// A soft budget for optional renderer retention, separate from process memory
/// and from content that cannot safely release its renderer.
nonisolated struct ContentRetentionPolicy: Sendable {
  struct Candidate: Sendable {
    let id: Worktree.ID
    let estimatedBytes: UInt64
  }

  var budgetBytes: UInt64
  static let maximumWorktrees = 32
  /// Retained regardless of the estimate. A single full-screen pane on a large
  /// display estimates in the hundreds of megabytes, so a pure budget fit keeps
  /// only the selected worktree and every switch pays a full tree remount —
  /// exactly the cost retention exists to avoid. The estimate governs how far
  /// above this floor retention may go, not whether retention happens at all.
  static let minimumWorktrees = 3
  static let unknownContentBytes: UInt64 = 64 * 1024 * 1024

  /// Conservative fit to isolated native retention measurements: viewport
  /// storage plus renderer overhead. This is not a process-memory ceiling.
  static func terminalBytes(displayedTargetBytes: UInt64) -> UInt64 {
    let (buffers, buffersOverflow) = displayedTargetBytes.multipliedReportingOverflow(by: 8)
    let (total, totalOverflow) = buffers.addingReportingOverflow(12 * 1024 * 1024)
    return buffersOverflow || totalOverflow ? .max : total
  }

  func retained(_ candidates: [Candidate], selected: Worktree.ID?) -> [Worktree.ID] {
    var remaining = budgetBytes
    var included: Set<Worktree.ID> = []
    func include(_ candidate: Candidate) {
      included.insert(candidate.id)
      remaining -= min(remaining, candidate.estimatedBytes)
    }
    if let selected, let candidate = candidates.first(where: { $0.id == selected }) {
      include(candidate)
    }
    // The floor goes first and is charged to the budget. Candidates arrive
    // most-recent-first, so it is the worktrees the user is switching between
    // that stay; filling it afterwards would let cheap older ones take the slots.
    for candidate in candidates where included.count < Self.minimumWorktrees {
      guard !included.contains(candidate.id) else { continue }
      include(candidate)
    }
    for candidate in candidates {
      guard included.count < Self.maximumWorktrees else { break }
      guard !included.contains(candidate.id), candidate.estimatedBytes <= remaining else {
        continue
      }
      include(candidate)
    }
    // Selection first, then recency: the result is fed back as the next order.
    var emitted: Set<Worktree.ID> = []
    let rest = candidates.map(\.id).filter {
      included.contains($0) && $0 != selected && emitted.insert($0).inserted
    }
    guard let selected, included.contains(selected) else { return rest }
    return [selected] + rest
  }
}

extension ContentRetentionPolicy: DependencyKey {
  static var liveValue: Self {
    Self(
      budgetBytes: min(
        1024 * 1024 * 1024, max(256 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 32)))
  }
  static let testValue = Self(budgetBytes: 8 * unknownContentBytes)
}
