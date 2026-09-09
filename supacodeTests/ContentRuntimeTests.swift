import AppKit
import ConcurrencyExtras
import Observation
import Testing

@testable import supacode

@MainActor
struct ContentRuntimeTests {
  @Test func provisioningInvalidatesOnlyTheDestinationRendererObservation() {
    let runtime = ContentRuntime()
    let destination = MockContent()
    let sibling = MockContent()
    let destinationChanges = LockIsolated(0)
    let siblingChanges = LockIsolated(0)
    withObservationTracking {
      _ = runtime.renderer(for: destination.id)
    } onChange: {
      destinationChanges.withValue { $0 += 1 }
    }
    withObservationTracking {
      _ = runtime.renderer(for: sibling.id)
    } onChange: {
      siblingChanges.withValue { $0 += 1 }
    }

    #expect(runtime.provision(destination, at: .fallback))
    #expect(destinationChanges.value == 1)
    #expect(siblingChanges.value == 0)
    #expect(runtime.renderer(for: destination.id) === destination.renderer)
  }

  @MainActor
  private final class MockContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private(set) var startSessionCalls = 0
    private(set) var hibernateCalls = 0
    private var view: NSView?

    init(id: ContentID = ContentID()) {
      self.id = id
    }

    var renderer: NSView? { view }

    func startSession(at geometry: ContentGeometry) {
      startSessionCalls += 1
      view = NSView()
    }

    func hibernate() {
      hibernateCalls += 1
      view = nil
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .terminal(TerminalContentState(workingDirectory: nil)))
    }
  }

  @Test func lifecycleChangesInvalidateOnlyTheirContent() {
    let runtime = ContentRuntime()
    let destination = MockContent()
    let sibling = MockContent()
    #expect(runtime.provision(destination, at: .fallback))
    #expect(runtime.provision(sibling, at: .fallback))
    let siblingChanges = LockIsolated(0)
    withObservationTracking {
      _ = runtime.renderer(for: sibling.id)
      _ = runtime.content(for: sibling.id)
    } onChange: {
      siblingChanges.withValue { $0 += 1 }
    }

    let mutations: [() -> Void] = [
      { runtime.hibernate(destination.id) },
      { runtime.startSession(destination.id, at: .fallback) },
      { runtime.remove(destination.id, tombstone: false) },
    ]
    for mutate in mutations {
      let changes = LockIsolated(0)
      withObservationTracking {
        _ = runtime.renderer(for: destination.id)
      } onChange: {
        changes.withValue { $0 += 1 }
      }
      mutate()
      #expect(changes.value == 1)
      #expect(siblingChanges.value == 0)
    }
    #expect(destination.startSessionCalls == 2)
    #expect(destination.hibernateCalls == 1)
    #expect(runtime.renderer(for: destination.id) == nil)
  }

  @Test func redundantLifecycleRequestsDoNotInvalidateReaders() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    let liveChanges = LockIsolated(0)
    withObservationTracking {
      _ = runtime.renderer(for: content.id)
    } onChange: {
      liveChanges.withValue { $0 += 1 }
    }
    runtime.startSession(content.id, at: .fallback)
    #expect(liveChanges.value == 0)
    #expect(content.startSessionCalls == 1)

    runtime.hibernate(content.id)
    let dormantChanges = LockIsolated(0)
    withObservationTracking {
      _ = runtime.renderer(for: content.id)
    } onChange: {
      dormantChanges.withValue { $0 += 1 }
    }
    runtime.hibernate(content.id)
    #expect(dormantChanges.value == 0)
    #expect(content.hibernateCalls == 1)
  }

  @Test func provisionStartsTheSessionExactlyOnce() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    #expect(content.startSessionCalls == 1)
    #expect(runtime.provision(content, at: .fallback) == false)
    #expect(content.startSessionCalls == 1)
  }

  @Test func provisionIsRefusedWhileTombstoned() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: true)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback) == false)
    #expect(replacement.startSessionCalls == 0)
    #expect(runtime.content(for: content.id) == nil)
  }

  @Test func confirmKillClearsTheTombstoneAndAllowsReProvision() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: true)
    runtime.confirmKill(content.id)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback))
    #expect(replacement.startSessionCalls == 1)
    #expect(runtime.content(for: content.id) === replacement)
  }

  @Test func hibernateKeepsTheEntryRegistered() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    content.hibernate()
    #expect(content.hibernateCalls == 1)
    #expect(runtime.content(for: content.id) === content)
  }

  @Test func rendererIsNilForUnknownAndHibernatedContent() {
    let runtime = ContentRuntime()
    #expect(runtime.renderer(for: ContentID()) == nil)
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    #expect(runtime.renderer(for: content.id) != nil)
    content.hibernate()
    #expect(runtime.renderer(for: content.id) == nil)
  }

  @Test func removeWithoutTombstoneUnregistersAndAllowsReProvision() {
    let runtime = ContentRuntime()
    let content = MockContent()
    #expect(runtime.provision(content, at: .fallback))
    runtime.remove(content.id, tombstone: false)
    #expect(runtime.content(for: content.id) == nil)
    #expect(runtime.renderer(for: content.id) == nil)
    let replacement = MockContent(id: content.id)
    #expect(runtime.provision(replacement, at: .fallback))
    #expect(replacement.startSessionCalls == 1)
  }
}
