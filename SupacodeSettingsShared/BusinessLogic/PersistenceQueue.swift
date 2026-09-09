import Foundation

/// FIFO disk work submitted synchronously at mutation time. A serial queue,
/// rather than separately scheduled Tasks, preserves the caller's write order.
public nonisolated final class PersistenceQueue: @unchecked Sendable {
  public static let shared = PersistenceQueue()
  private let queue = DispatchQueue(label: "app.supabit.supacode.settings-writer", qos: .utility)
  private let key = DispatchSpecificKey<Bool>()

  private init() { queue.setSpecific(key: key, value: true) }

  public func enqueue(_ operation: @escaping @Sendable () -> Void) {
    queue.async(execute: operation)
  }

  /// Reads and termination must not overtake a previously accepted write.
  public func flush() {
    guard DispatchQueue.getSpecific(key: key) != true else { return }
    queue.sync {}
  }
}
