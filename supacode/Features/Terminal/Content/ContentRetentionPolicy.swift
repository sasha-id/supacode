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
    var result: [Worktree.ID] = []
    var included: Set<Worktree.ID> = []
    if let selected, let candidate = candidates.first(where: { $0.id == selected }) {
      result.append(selected)
      included.insert(selected)
      remaining -= min(remaining, candidate.estimatedBytes)
    }
    for candidate in candidates {
      guard result.count < Self.maximumWorktrees else { break }
      guard !included.contains(candidate.id), candidate.estimatedBytes <= remaining else {
        continue
      }
      remaining -= candidate.estimatedBytes
      included.insert(candidate.id)
      result.append(candidate.id)
    }
    return result
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
