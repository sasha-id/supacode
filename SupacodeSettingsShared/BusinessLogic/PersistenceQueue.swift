import Foundation

/// Serial disk work submitted at mutation time. Pending automatic snapshots
/// coalesce per destination; explicit saves and reads fence earlier batches.
public nonisolated final class PersistenceQueue: @unchecked Sendable {
  public static let shared = PersistenceQueue()
  private let queue = DispatchQueue(label: "app.supabit.supacode.settings-writer", qos: .utility)
  private let key = DispatchSpecificKey<Bool>()
  private let lock = NSLock()
  private var pending: [CoalescingKey: Save] = [:]

  init() { queue.setSpecific(key: key, value: true) }

  public struct CoalescingKey: Hashable, Sendable {
    private let owner: ObjectIdentifier
    private let name: String

    public init(owner: AnyObject, name: String) {
      self.owner = ObjectIdentifier(owner)
      self.name = name
    }
  }

  public func save(
    coalescing key: CoalescingKey?,
    operation: @escaping @Sendable () throws -> Void,
    completion: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    lock.withLock {
      if let key, let save = pending[key] {
        save.operation = operation
        save.completions.append(completion)
        return
      }
      // Explicit saves fence all earlier snapshots, including other stores.
      if key == nil { pending.removeAll() }
      let save = Save(operation: operation, completion: completion)
      if let key { pending[key] = save }
      queue.async { [self] in
        let (operation, completions) = lock.withLock {
          if let key, pending[key] === save { pending.removeValue(forKey: key) }
          return (save.operation, save.completions)
        }
        let result = Result { try operation() }
        for completion in completions { completion(result) }
      }
    }
  }

  public func enqueue(_ operation: @escaping @Sendable () -> Void) {
    lock.withLock {
      pending.removeAll()
      queue.async(execute: operation)
    }
  }

  /// Reads and termination must not overtake a previously accepted write.
  public func flush() {
    read {}
  }

  /// Keep hydration and its persisted-value bookkeeping atomic with writes.
  public func read<Value>(_ operation: () throws -> Value) rethrows -> Value {
    if DispatchQueue.getSpecific(key: key) == true { return try operation() }
    lock.withLock { pending.removeAll() }
    return try queue.sync(execute: operation)
  }

  // Mutable fields are accessed only under the enclosing queue's lock. Once
  // dequeued, a save is removed from pending before its operation can run.
  private final class Save: @unchecked Sendable {
    var operation: @Sendable () throws -> Void
    var completions: [@Sendable (Result<Void, any Error>) -> Void]

    init(
      operation: @escaping @Sendable () throws -> Void,
      completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
      self.operation = operation
      self.completions = [completion]
    }
  }
}
