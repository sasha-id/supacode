import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Synchronization
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct PersistenceQueueTests {
  @Test func distinctDestinationsNeverSupersedeEachOther() {
    let queue = PersistenceQueue()
    let gate = DispatchSemaphore(value: 0)
    queue.enqueue { gate.wait() }
    let first = NSObject()
    let second = NSObject()
    let keys = [
      PersistenceQueue.CoalescingKey(owner: first, name: "settings"),
      PersistenceQueue.CoalescingKey(owner: second, name: "settings"),
      PersistenceQueue.CoalescingKey(owner: first, name: "sidebar"),
    ]
    let writes = Mutex<[Int]>([])
    for value in 0..<6 {
      queue.save(coalescing: keys[value % 3], operation: { writes.withLock { $0.append(value) } }) { result in
        #expect(throws: Never.self) { try result.get() }
      }
    }
    gate.signal()
    queue.flush()
    #expect(writes.withLock { $0 } == [3, 4, 5])
  }

  @Test func coalescedFailureReachesEveryCallerAndDoesNotPoisonNextSave() {
    enum WriteFailure: Error { case unavailable }
    let queue = PersistenceQueue()
    let gate = DispatchSemaphore(value: 0)
    queue.enqueue { gate.wait() }
    let owner = NSObject()
    let key = PersistenceQueue.CoalescingKey(owner: owner, name: "settings")
    let failures = Mutex<[Int]>([])
    let attempts = Mutex(0)
    for value in 1...3 {
      queue.save(
        coalescing: key,
        operation: {
          attempts.withLock { $0 += 1 }
          throw WriteFailure.unavailable
        }
      ) { result in
        #expect(throws: WriteFailure.self) { try result.get() }
        failures.withLock { $0.append(value) }
      }
    }
    gate.signal()
    queue.flush()
    #expect(attempts.withLock { $0 } == 1)
    #expect(failures.withLock { $0 } == [1, 2, 3])
    let recovered = Mutex(false)
    queue.save(coalescing: key, operation: {}) { result in
      #expect(throws: Never.self) { try result.get() }
      recovered.withLock { $0 = true }
    }
    queue.flush()
    #expect(recovered.withLock { $0 })
  }

  @Test func aRunningSaveCannotAbsorbLaterSnapshots() {
    let queue = PersistenceQueue()
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let owner = NSObject()
    let key = PersistenceQueue.CoalescingKey(owner: owner, name: "settings")
    let writes = Mutex<[Int]>([])
    queue.save(
      coalescing: key,
      operation: {
        started.signal()
        finish.wait()
        writes.withLock { $0.append(1) }
      }
    ) { result in
      #expect(throws: Never.self) { try result.get() }
    }
    #expect(started.wait(timeout: .now() + 5) == .success)
    for value in 2...3 {
      queue.save(coalescing: key, operation: { writes.withLock { $0.append(value) } }) { result in
        #expect(throws: Never.self) { try result.get() }
      }
    }
    finish.signal()
    queue.flush()
    #expect(writes.withLock { $0 } == [1, 3])
  }

  @Test func pendingAutomaticSavesKeepLatestValueAndCompleteEveryCaller() {
    let queue = PersistenceQueue()
    let gate = DispatchSemaphore(value: 0)
    queue.enqueue { gate.wait() }
    let owner = NSObject()
    let key = PersistenceQueue.CoalescingKey(owner: owner, name: "settings")
    let writes = Mutex<[Int]>([])
    let completed = Mutex<[Int]>([])
    for value in 1...3 {
      queue.save(coalescing: key, operation: { writes.withLock { $0.append(value) } }) { result in
        #expect(throws: Never.self) { try result.get() }
        completed.withLock { $0.append(value) }
      }
    }
    gate.signal()
    queue.flush()
    #expect(writes.withLock { $0 } == [3])
    #expect(completed.withLock { $0 } == [1, 2, 3])
  }

  @Test func explicitSaveSeparatesAutomaticBatches() {
    let queue = PersistenceQueue()
    let gate = DispatchSemaphore(value: 0)
    queue.enqueue { gate.wait() }
    let owner = NSObject()
    let key = PersistenceQueue.CoalescingKey(owner: owner, name: "settings")
    let writes = Mutex<[Int]>([])
    for (value, automatic) in [(1, true), (2, false), (3, true), (4, true)] {
      queue.save(coalescing: automatic ? key : nil, operation: { writes.withLock { $0.append(value) } }) { result in
        #expect(throws: Never.self) { try result.get() }
      }
    }
    gate.signal()
    queue.flush()
    #expect(writes.withLock { $0 } == [1, 2, 4])
  }
}

struct SettingsFilePersistenceTests {
  @Test(.dependencies) @MainActor func reloadCannotPublishACacheOlderThanAnAcceptedWrite() async throws {
    let backing = SettingsTestStorage().storage
    let duringRead = Mutex<(@Sendable () -> Void)?>(nil)
    defer { duringRead.withLock { $0 = nil } }
    try await withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { url in
          let data = try backing.load(url)
          let callback = duringRead.withLock { callback in
            defer { callback = nil }
            return callback
          }
          callback?()
          return data
        }, save: backing.save)
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      @Shared(.settingsFile) var settings
      let original = settings
      var changed = original
      changed.global.appearanceMode = .light
      let next = changed
      let key = SettingsFileKey(urls: urls)
      withEscapedDependencies { dependencies in
        duringRead.withLock { callback in
          callback = {
            dependencies.yield {
              key.save(
                next, context: .didSet,
                continuation: SaveContinuation { result in
                  #expect(throws: Never.self) { try result.get() }
                })
            }
            // An off-writer reload lets the newer write complete before its
            // stale cache publication. A serialized reload finishes first.
            PersistenceQueue.shared.flush()
          }
        }
      }
      try await $settings.load()
      PersistenceQueue.shared.flush()
      #expect(try JSONDecoder().decode(GlobalSettings.self, from: backing.load(urls.config)).appearanceMode == .light)
      try await Self.automaticSave(original, key: key)
      #expect(try JSONDecoder().decode(GlobalSettings.self, from: backing.load(urls.config)).appearanceMode == .dark)
    }
  }

  @Test(.dependencies) @MainActor func rebindingStorageDoesNotReuseAnotherDestinationsCache() async throws {
    let original = SettingsTestStorage().storage
    let replacement = SettingsTestStorage().storage
    try await withDependencies {
      $0.settingsFileStorage = original
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      @Shared(.settingsFile) var settings
      var rebound = original
      rebound.load = replacement.load
      rebound.save = replacement.save
      try await withDependencies {
        $0.settingsFileStorage = rebound
      } operation: {
        try await Self.automaticSave(settings, key: SettingsFileKey(urls: urls))
      }
      #expect(try replacement.load(urls.config) == original.load(urls.config))
      #expect(try replacement.load(urls.routes) == original.load(urls.routes))
      #expect(try replacement.load(urls.repositories) == original.load(urls.repositories))
    }
  }

  @Test(.dependencies, arguments: [false, true]) @MainActor
  func partialFailureRetriesOnlyUnpersistedDomains(revertOnRetry: Bool) async throws {
    let storage = SettingsTestStorage().storage
    let writes = Mutex<[URL]>([])
    let failedURL = Mutex<URL?>(nil)
    enum WriteFailure: Error { case unavailable }
    try await withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: storage.load,
        save: { data, url in
          writes.withLock { $0.append(url) }
          try storage.save(data, url)
          if failedURL.withLock({ $0 == url }) { throw WriteFailure.unavailable }
        })
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      @Shared(.settingsFile) var settings
      var changed = settings
      changed.global.appearanceMode = .light
      changed.repositoryRoots = ["/tmp/partial-write"]
      changed.repositories["/tmp/partial-write"] = .default
      let key = SettingsFileKey(urls: urls)
      writes.withLock { $0.removeAll() }
      failedURL.withLock { $0 = urls.routes }
      await #expect(throws: WriteFailure.self) {
        try await Self.automaticSave(changed, key: key)
      }
      #expect(writes.withLock { $0 } == [urls.config, urls.routes])
      failedURL.withLock { $0 = nil }
      writes.withLock { $0.removeAll() }
      try await Self.automaticSave(revertOnRetry ? settings : changed, key: key)
      if revertOnRetry {
        #expect(writes.withLock { $0 } == [urls.config, urls.routes])
        #expect(try JSONDecoder().decode(RoutesFile.self, from: storage.load(urls.routes)).local.isEmpty)
        return
      }
      #expect(writes.withLock { $0 } == [urls.routes, urls.repositories])
      #expect(
        try JSONDecoder().decode(RoutesFile.self, from: storage.load(urls.routes)).local == ["/tmp/partial-write"])
      #expect(
        try JSONDecoder().decode([String: RepositorySettings].self, from: storage.load(urls.repositories))[
          "/tmp/partial-write"] != nil)
    }
  }

  private static func automaticSave(_ value: SettingsFile, key: SettingsFileKey) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      key.save(
        value, context: .didSet,
        continuation: SaveContinuation { result in
          continuation.resume(with: result.map { _ in () })
        })
    }
  }

  @Test(.dependencies) @MainActor func loadedDomainsAreComparedByValueNotJSONFormatting() throws {
    let storage = SettingsTestStorage().storage
    @Dependency(\.settingsFileURLs) var urls
    let encoder = JSONEncoder()
    try storage.save(encoder.encode(GlobalSettings.default), urls.config)
    try storage.save(Data("{\"remote\":[],\"local\":[]}".utf8), urls.routes)
    try storage.save(Data("{}".utf8), urls.repositories)
    let writes = Mutex<[URL]>([])
    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: storage.load,
        save: { data, url in
          writes.withLock { $0.append(url) }
          try storage.save(data, url)
        })
    } operation: {
      @Shared(.settingsFile) var settings
      $settings.withLock { $0.global.appearanceMode = .light }
      PersistenceQueue.shared.flush()
      #expect(writes.withLock { $0 } == [urls.config])
    }
  }

  @Test(.dependencies, arguments: [false, true]) @MainActor
  func automaticChangeWritesOnlyTheChangedDomain(routesChanged: Bool) throws {
    let storage = SettingsTestStorage().storage
    let writes = Mutex<[URL]>([])
    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: storage.load,
        save: { data, url in
          writes.withLock { $0.append(url) }
          try storage.save(data, url)
        })
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      @Shared(.settingsFile) var settings
      writes.withLock { $0.removeAll() }
      $settings.withLock {
        if routesChanged { $0.repositoryRoots = ["/tmp/performance-repo"] } else { $0.global.appearanceMode = .light }
      }
      PersistenceQueue.shared.flush()
      #expect(writes.withLock { $0 } == [routesChanged ? urls.routes : urls.config])
      if routesChanged {
        let data = try storage.load(urls.routes)
        #expect(try JSONDecoder().decode(RoutesFile.self, from: data).local == ["/tmp/performance-repo"])
      } else {
        let data = try storage.load(urls.config)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).appearanceMode == .light)
      }
      writes.withLock { $0.removeAll() }
      $settings.withLock { $0.pinnedWorktreeIDs = ["presentation-only"] }
      PersistenceQueue.shared.flush()
      #expect(writes.withLock { $0.isEmpty })
    }
  }

  @Test(.dependencies) @MainActor func queuedWriteUsesTheCallersDefaultDependencyInstance() async throws {
    // No storage override: a wrapper resolved on a dispatch queue loses the
    // test's dependency-cache identity and writes to a different in-memory store.
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.settingsFileURLs) var urls
    @Shared(.settingsFile) var settings
    let destination = storage
    $settings.withLock { $0.global.appearanceMode = .dark }
    try await $settings.save()
    let data = try destination.load(urls.config)
    #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).appearanceMode == .dark)
  }

  @Test(.dependencies) @MainActor func writesRunOffMainAndExplicitSaveReportsFailure() async throws {
    let storage = SettingsTestStorage().storage
    let mainThreadWrites = Mutex<[Bool]>([])
    let failWrites = Mutex(false)
    enum WriteFailure: Error { case unavailable }
    try await withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: storage.load,
        save: { data, url in
          mainThreadWrites.withLock { $0.append(Thread.isMainThread) }
          if failWrites.withLock({ $0 }) { throw WriteFailure.unavailable }
          try storage.save(data, url)
        })
    } operation: {
      @Shared(.settingsFile) var settings
      mainThreadWrites.withLock { $0.removeAll() }
      $settings.withLock { $0.global.appearanceMode = .dark }
      try await $settings.save()
      #expect(!mainThreadWrites.withLock { $0.isEmpty })
      #expect(mainThreadWrites.withLock { $0.allSatisfy { !$0 } })
      failWrites.withLock { $0 = true }
      await #expect(throws: WriteFailure.self) { try await $settings.save() }
    }
  }

  @Test(.dependencies) func loadWritesDefaultsWhenMissing() throws {
    let storage = SettingsTestStorage()

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func loadFallsBackToLegacySettingsWhenNewStoreEmpty() throws {
    let store = InMemorySettingsFileStorage()
    var legacy = SettingsFile.default
    legacy.global.appearanceMode = .dark
    legacy.repositoryRoots = ["/tmp/repo-a"]
    try store.save(JSONEncoder().encode(legacy), SupacodePaths.legacySettingsURL)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try store.load($0) }, save: { try store.save($0, $1) })
      $0.settingsFileURLs = .live
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The new store is empty but a legacy settings.json exists: read it, and do
    // NOT write defaults (which would mask a pending or failed migration and let
    // the retire step treat those defaults as a landed migration).
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.repositoryRoots == ["/tmp/repo-a"])
    #expect((try? store.load(SupacodePaths.configURL)) == nil)
  }

  @Test(.dependencies) func loadServesInitialWithoutPersistingWhenASliceIsUnreadable() throws {
    let store = InMemorySettingsFileStorage()
    var real = GlobalSettings.default
    real.defaultEditorID = "custom-editor-xyz"
    let realConfig = try JSONEncoder().encode(real)
    try store.save(realConfig, SupacodePaths.configURL)

    let settings: SettingsFile = withDependencies {
      // config.json exists but fails to read with a non-ENOENT (transient) error.
      $0.settingsFileStorage = SettingsFileStorage(
        load: { url in
          if url == SupacodePaths.configURL { throw CocoaError(.fileReadNoPermission) }
          return try store.load(url)
        },
        save: { try store.save($0, $1) }
      )
      $0.settingsFileURLs = .live
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // Served the initial default, NOT the real (unreadable) value.
    #expect(settings.global.defaultEditorID == GlobalSettings.default.defaultEditorID)
    // The real config file was never overwritten with defaults.
    #expect((try? store.load(SupacodePaths.configURL)) == realConfig)
  }

  @Test(.dependencies) func degradedLoadRefusesLaterSaveToProtectRealData() throws {
    let store = InMemorySettingsFileStorage()
    var real = GlobalSettings.default
    real.defaultEditorID = "custom-editor-xyz"
    let realConfig = try JSONEncoder().encode(real)
    try store.save(realConfig, SupacodePaths.configURL)

    withDependencies {
      // config.json exists but fails to read: the store loads degraded.
      $0.settingsFileStorage = SettingsFileStorage(
        load: { url in
          if url == SupacodePaths.configURL { throw CocoaError(.fileReadNoPermission) }
          return try store.load(url)
        },
        save: { try store.save($0, $1) }
      )
      $0.settingsFileURLs = .live
      $0.settingsStoreHealth = SettingsStoreHealth()
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      // A mutation after a degraded load must NOT persist defaults over the real data.
      $settings.withLock { $0.global.defaultEditorID = "changed" }
    }

    // The real config file is untouched: the degraded store refused the save.
    #expect((try? store.load(SupacodePaths.configURL)) == realConfig)
  }

  @Test(.dependencies) func partialSplitStoreServesLegacyAndRefusesSave() throws {
    let store = InMemorySettingsFileStorage()
    // A partial split store (interrupted relocation): config + repositories present,
    // routes.json ABSENT.
    try store.save(JSONEncoder().encode(GlobalSettings.default), SupacodePaths.configURL)
    try store.save(JSONEncoder().encode([String: RepositorySettings]()), SupacodePaths.reposURL)
    // The legacy file holds the complete real data (with roots).
    var legacy = SettingsFile.default
    legacy.repositoryRoots = ["/tmp/repo-a"]
    let legacyData = try JSONEncoder().encode(legacy)
    try store.save(legacyData, SupacodePaths.legacySettingsURL)

    withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try store.load($0) }, save: { try store.save($0, $1) })
      $0.settingsFileURLs = .live
      $0.settingsStoreHealth = SettingsStoreHealth()
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      // The partial store serves the legacy real data, not empty defaults.
      #expect(settings.repositoryRoots == ["/tmp/repo-a"])
      // A mutation must not complete the partial store with defaults (save refused).
      $settings.withLock { $0.repositoryRoots = [] }
    }

    // routes.json was never written and the legacy real data survives untouched.
    #expect((try? store.load(SupacodePaths.routesURL)) == nil)
    #expect((try? store.load(SupacodePaths.legacySettingsURL)) == legacyData)
  }

  @Test(.dependencies) func saveAndReload() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b"]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.appearanceMode == .dark)
    #expect(reloaded.repositoryRoots == ["/tmp/repo-a", "/tmp/repo-b"])
    // `pinnedWorktreeIDs` is sidebar curation now (in `SidebarState`), never
    // persisted through the settings store, so it reloads empty.
    #expect(reloaded.pinnedWorktreeIDs.isEmpty)
  }

  @Test(.dependencies) func savingSplitsAcrossConfigRoutesAndRepositories() async throws {
    let storage = SettingsTestStorage()

    try await withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
        $0.repositoryRoots = ["/tmp/repo-a"]
        $0.remoteRepositoryRoots = ["me@box/srv/repo"]
        $0.repositories = ["/tmp/repo-a/": .default]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
      }

      try await $settings.save()

      @Dependency(\.settingsFileURLs) var urls

      // `config.json` is the raw `GlobalSettings`, with no "global" wrapper and
      // no persisted pin list.
      let configData = try storage.storage.load(urls.config)
      let configObject = try #require(
        JSONSerialization.jsonObject(with: configData) as? [String: Any])
      #expect(configObject["global"] == nil)
      #expect(configObject["appearanceMode"] != nil)
      #expect(configObject["pinnedWorktreeIDs"] == nil)
      let decodedGlobal = try JSONDecoder().decode(GlobalSettings.self, from: configData)
      #expect(decodedGlobal.appearanceMode == .dark)

      // `routes.json` mirrors the local / remote roots.
      let routesData = try storage.storage.load(urls.routes)
      let routes = try JSONDecoder().decode(RoutesFile.self, from: routesData)
      #expect(routes.local == ["/tmp/repo-a"])
      #expect(routes.remote == ["me@box/srv/repo"])

      // `repos.json` is the per-repo settings map, keyed by repository id.
      let repositoriesData = try storage.storage.load(urls.repositories)
      let repositories = try JSONDecoder().decode(
        [String: RepositorySettings].self, from: repositoriesData)
      #expect(repositories["/tmp/repo-a/"] != nil)
    }
  }

  @Test(.dependencies) func loadRotatesCorruptRoutesPreservingConfig() throws {
    let storage = SettingsTestStorage()
    var global = GlobalSettings.default
    global.appearanceMode = .dark

    let settings: SettingsFile = try withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      try storage.storage.save(try JSONEncoder().encode(global), urls.config)
      try storage.storage.save(Data("{ not json".utf8), urls.routes)
      // repos.json absent.
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The corrupt routes slice falls back to empty without discarding config.
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.repositoryRoots.isEmpty)
    #expect(settings.remoteRepositoryRoots.isEmpty)
  }

  @Test(.dependencies) func loadRotatesCorruptRepositoriesPreservingConfig() throws {
    let storage = SettingsTestStorage()
    var global = GlobalSettings.default
    global.appearanceMode = .dark

    let settings: SettingsFile = try withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Dependency(\.settingsFileURLs) var urls
      try storage.storage.save(try JSONEncoder().encode(global), urls.config)
      try storage.storage.save(Data("garbage".utf8), urls.repositories)
      // routes.json absent.
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The corrupt repositories slice falls back to empty without discarding config.
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.repositories.isEmpty)
    #expect(settings.repositoryRoots.isEmpty)
  }

  @Test func ghosttyUserConfigModePersistsThroughRoundTrip() throws {
    var settings = GlobalSettings.default
    settings.ghosttyUserConfigMode = .exclusive
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.ghosttyUserConfigMode == .exclusive)
  }

  // Files written before the key existed decode to the merge default, never a throw.
  @Test func ghosttyUserConfigModeDefaultsWhenKeyMissing() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "ghosttyUserConfigMode")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stripped)
    #expect(decoded.ghosttyUserConfigMode == .mergeAfterDefault)
  }

  // A corrupt value falls back instead of throwing, which would reset the file.
  @Test func ghosttyUserConfigModeRejectsUnknownValue() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["ghosttyUserConfigMode"] = "bogus"
    let corrupted = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: corrupted)
    #expect(decoded.ghosttyUserConfigMode == .mergeAfterDefault)
  }

  @Test func globalToggleVisibilityHotkeyPersistsThroughRoundTrip() throws {
    var settings = GlobalSettings.default
    settings.globalToggleVisibilityHotkey = AppShortcutOverride(keyCode: 49, modifiers: [.command, .shift])
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(decoded.globalToggleVisibilityHotkey == settings.globalToggleVisibilityHotkey)
  }

  // Files written before the key existed decode to nil (unbound), never a throw.
  @Test func globalToggleVisibilityHotkeyDefaultsToNilWhenKeyMissing() throws {
    let data = try JSONEncoder().encode(GlobalSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "globalToggleVisibilityHotkey")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: stripped)
    #expect(decoded.globalToggleVisibilityHotkey == nil)
  }

  // A corrupt hotkey value falls back to nil instead of resetting the whole file.
  @Test func globalToggleVisibilityHotkeyFallsBackWhenCorrupt() throws {
    var global = GlobalSettings.default
    global.appearanceMode = .light
    let data = try JSONEncoder().encode(global)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["globalToggleVisibilityHotkey"] = "not-an-object"
    let corrupted = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(GlobalSettings.self, from: corrupted)
    #expect(decoded.globalToggleVisibilityHotkey == nil)
    #expect(decoded.appearanceMode == .light)
  }

  @Test(.dependencies) func invalidJSONResetsToDefaults() throws {
    let storage = MutableTestStorage(initialData: Data("{".utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func decodesLegacyAutoArchiveTrueAsMergedWorktreeActionArchive() throws {
    let legacy = LegacySettingsFileWithArchiveFlag(
      global: LegacyGlobalSettingsWithArchiveFlag(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        automaticallyArchiveMergedWorktrees: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.mergedWorktreeAction == .archive)
  }

  @Test(.dependencies) func decodesLegacyAutoArchiveFalseAsMergedWorktreeActionIgnore() throws {
    let legacy = LegacySettingsFileWithArchiveFlag(
      global: LegacyGlobalSettingsWithArchiveFlag(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        automaticallyArchiveMergedWorktrees: false
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.mergedWorktreeAction == .ignore)
  }

  @Test(.dependencies) func roundTripsMergedWorktreeActionDelete() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.mergedWorktreeAction = .delete
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.mergedWorktreeAction == .delete)
  }

  @Test(.dependencies) func decodesMissingInAppNotificationsEnabled() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.updatesAutomaticallyCheckForUpdates == false)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
    #expect(settings.global.inAppNotificationsEnabled == true)
    // Missing key (pre-feature file) decodes to the default sound.
    #expect(settings.global.notificationSound == .hero)
    #expect(settings.global.systemNotificationsEnabled == false)
    // Missing key (pre-feature file) decodes to the default, now false.
    #expect(settings.global.moveNotifiedWorktreeToTop == false)
    #expect(settings.global.analyticsEnabled == true)
    #expect(settings.global.crashReportsEnabled == true)
    #expect(settings.global.githubIntegrationEnabled == true)
    #expect(settings.global.deleteBranchOnDeleteWorktree == true)
    #expect(settings.global.mergedWorktreeAction == .ignore)
    #expect(settings.global.promptForWorktreeCreation == true)
    #expect(settings.global.defaultWorktreeBaseDirectoryPath == nil)
    #expect(settings.global.defaultEditorID == OpenWorktreeAction.automaticSettingsID)
    #expect(settings.repositoryRoots.isEmpty)
    #expect(settings.pinnedWorktreeIDs.isEmpty)
    // Pre-existing files must not flip the toggle on upgrade.
    #expect(settings.global.terminalThemeSyncEnabled == false)
  }

  @Test func freshInstallDefaultsTerminalThemeSyncEnabledToTrue() {
    #expect(GlobalSettings.default.terminalThemeSyncEnabled == true)
  }

  // Opaque is the performance default for everyone: a fresh install and an
  // existing settings file predating this key must both land on `false`.
  @Test func freshInstallDefaultsTerminalTranslucencyEnabledToFalse() {
    #expect(GlobalSettings.default.terminalTranslucencyEnabled == false)
  }

  @Test(.dependencies) func decodesMissingTerminalTranslucencyEnabledAsFalse() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.terminalTranslucencyEnabled == false)
  }

  @Test(.dependencies) func decodesLegacyConfirmBeforeQuitTrueAsAlways() throws {
    // Opt-out users (`confirmBeforeQuit = true` in the old single-toggle model)
    // must land on `.always`, NOT `.auto`. `.auto` would silently re-enable the
    // dialog only when active work exists, which is the opposite of what they
    // configured ("ask me every time, no matter what").
    let legacy = LegacySettingsFileWithQuitToggle(
      global: LegacyGlobalSettingsWithQuitToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        confirmBeforeQuit: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmQuitMode == .always)
  }

  @Test(.dependencies) func decodesLegacyConfirmBeforeQuitFalseAsNever() throws {
    // Symmetric to the `true` case: explicit opt-out must stay opt-out.
    let legacy = LegacySettingsFileWithQuitToggle(
      global: LegacyGlobalSettingsWithQuitToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        confirmBeforeQuit: false
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmQuitMode == .never)
  }

  @Test(.dependencies) func freshInstallDefaultsConfirmQuitModeToAuto() throws {
    // Neither the new key nor the legacy key is present (fresh-installed
    // bundle). The decode must fall through to `.auto`, the new default.
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmQuitMode == .auto)
  }

  @Test(.dependencies) func roundTripsExplicitNotificationSound() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.notificationSound = .submarine }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    // An explicitly chosen sound must survive a save / reload round-trip.
    #expect(reloaded.global.notificationSound == .submarine)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledFalseToNever() throws {
    // A pre-picker file with the sound explicitly muted must stay muted, not
    // resurface as the default sound on upgrade.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: false
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.notificationSound == .never)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledTrueToDefault() throws {
    // Symmetric to the `false` case: the sound was on, so it folds to the default.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.notificationSound == .hero)
  }

  @Test(.dependencies) func decodesUnrecognizedNotificationSoundAsDefaultWithoutResettingSiblings() throws {
    // A hand-edited or downgraded file carrying a sound case this build doesn't
    // know yet. The `try?` must isolate the fallback to this one field.
    var global = GlobalSettings.default
    global.appearanceMode = .dark
    global.systemNotificationsEnabled = true
    global.updatesAutomaticallyDownloadUpdates = true

    let encoded = try JSONEncoder().encode(global)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["notificationSound"] = "futureSoundFromNewerBuild"
    // `config.json` is the raw global object, no "global" wrapper.
    let data = try JSONSerialization.data(withJSONObject: globalDict)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The unknown sound falls back to the default...
    #expect(settings.global.notificationSound == .hero)
    // ...but the rest of the file survives. This is what `try?` buys over `try`.
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.systemNotificationsEnabled == true)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
  }

  @Test(.dependencies) func roundTripsExplicitTerminalThemeSyncEnabled() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.terminalThemeSyncEnabled = true }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    // Explicit `true` must survive the asymmetric missing-key fallback.
    #expect(reloaded.global.terminalThemeSyncEnabled == true)
  }

  @Test(.dependencies) func decodesMissingConfirmCloseSurfaceAsTrue() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmCloseSurface)
  }

  @Test(.dependencies) func roundTripsExplicitConfirmCloseSurfaceDisabled() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.confirmCloseSurface = false }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(!reloaded.global.confirmCloseSurface)
  }

  @Test(.dependencies) func decodesLegacyConfirmCloseSurfaceTrueAsBusy() throws {
    let legacy = LegacySettingsFileWithCloseSurface(
      global: LegacyGlobalSettingsWithCloseSurface(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true,
        confirmCloseSurface: true
      ),
      repositories: [:]
    )
    let storage = MutableTestStorage(initialData: try JSONEncoder().encode(legacy.global))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmCloseTab == .busy)
  }

  @Test(.dependencies) func decodesLegacyConfirmCloseSurfaceFalseAsNever() throws {
    let legacy = LegacySettingsFileWithCloseSurface(
      global: LegacyGlobalSettingsWithCloseSurface(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true,
        confirmCloseSurface: false
      ),
      repositories: [:]
    )
    let storage = MutableTestStorage(initialData: try JSONEncoder().encode(legacy.global))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.confirmCloseTab == .never)
  }

  @Test(.dependencies) func freshInstallDefaultsConfirmCloseTabToBusy() throws {
    let storage = SettingsTestStorage()
    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }
    #expect(settings.global.confirmCloseTab == .busy)
  }

  @Test(.dependencies) func roundTripsExplicitConfirmCloseTabAlways() throws {
    let storage = SettingsTestStorage()
    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.confirmCloseTab = .always }
    }
    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }
    #expect(reloaded.global.confirmCloseTab == .always)
  }

  @Test(.dependencies) func decodesMissingRemoteSessionPersistenceEnabledAsTrue() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // Pre-feature files opt in by default (the setting is an opt-out).
    #expect(settings.global.remoteSessionPersistenceEnabled == true)
  }

  @Test(.dependencies) func decodesMissingTerminalHibernationEnabledAsTrue() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The Beta feature defaults on, so a pre-feature file decodes to on.
    #expect(settings.global.terminalHibernationEnabled == true)
  }

  @Test(.dependencies) func decodesMissingAutomaticRepositoryRefreshEnabledAsTrue() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // A pre-feature file omits the key; background refresh defaults on.
    #expect(settings.global.automaticRepositoryRefreshEnabled == true)
  }

  @Test(.dependencies) func decodesMissingAppVisibilityAsDefault() throws {
    // A file predating the menu bar feature falls through to the default, which
    // now shows the menu bar too.
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appVisibility == .dockAndMenuBar)
  }

  @Test(.dependencies) func decodesUnrecognizedAppVisibilityAsDefaultWithoutDiscardingTheFile() throws {
    // A throw here would reset the whole file to defaults and write it back, so
    // a hand-edited or newer-than-us value must fall through to the default.
    let file = SettingsFileWithRawAppVisibility(
      global: GlobalSettingsWithRawAppVisibility(
        appearanceMode: .light,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: false,
        appVisibility: "bogus"
      ),
      repositories: [:]
    )
    // `config.json` holds raw `GlobalSettings`, so seed just the global object.
    let data = try JSONEncoder().encode(file.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appVisibility == .dockAndMenuBar)
    // Both differ from `GlobalSettings.default`, so a reset-to-defaults would fail here.
    #expect(settings.global.appearanceMode == .light)
    #expect(settings.global.updatesAutomaticallyCheckForUpdates == false)
  }

  @Test(.dependencies) func decodesMistypedAppVisibilityAsDefaultWithoutDiscardingTheFile() throws {
    // A hand-edit can produce the wrong JSON type, not just an unknown string.
    let json = """
      {"appearanceMode":"light","updatesAutomaticallyCheckForUpdates":false,\
      "updatesAutomaticallyDownloadUpdates":false,"appVisibility":3}
      """
    let storage = MutableTestStorage(initialData: Data(json.utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appVisibility == .dockAndMenuBar)
    #expect(settings.global.appearanceMode == .light)
  }

  @Test(.dependencies) func roundTripsExplicitAppVisibility() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.appVisibility = .menuBar }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.appVisibility == .menuBar)
  }

  @Test(.dependencies) func roundTripsExplicitRemoteSessionPersistenceDisabled() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.remoteSessionPersistenceEnabled = false }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.remoteSessionPersistenceEnabled == false)
  }

  @Test(.dependencies) func decodesMissingNotificationRetentionLimitAsDefault() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.notificationRetentionLimit == .twoHundred)
  }

  @Test(.dependencies) func decodesUnrecognizedNotificationRetentionLimitAsDefault() throws {
    // A hand-edited file carrying a count that is not one of the offered tiers.
    var global = GlobalSettings.default
    global.systemNotificationsEnabled = true

    let encoded = try JSONEncoder().encode(global)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["notificationRetentionLimit"] = 150
    // `config.json` is the raw global object, no "global" wrapper.
    let data = try JSONSerialization.data(withJSONObject: globalDict)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The out-of-range value falls back to the default without resetting siblings.
    #expect(settings.global.notificationRetentionLimit == .twoHundred)
    #expect(settings.global.systemNotificationsEnabled == true)
  }

  @Test(.dependencies) func decodesMissingChromeTextSizeAsDefault() throws {
    // A file predating the accessibility text size has no `chromeTextSize` key
    // and must migrate to the system default size rather than failing to load.
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy.global)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.chromeTextSize == .default)
  }

  @Test(.dependencies) func decodesUnrecognizedChromeTextSizeAsDefaultWithoutDiscardingTheFile() throws {
    // An unknown size (older build, hand-edit) must fall back by itself rather
    // than throwing, which would reset every other setting in the file.
    let json = """
      {"appearanceMode":"light","updatesAutomaticallyCheckForUpdates":false,\
      "updatesAutomaticallyDownloadUpdates":false,"chromeTextSize":"gigantic"}
      """
    let storage = MutableTestStorage(initialData: Data(json.utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.chromeTextSize == .default)
    #expect(settings.global.appearanceMode == .light)
  }

  @Test(.dependencies) func decodesMistypedChromeTextSizeAsDefaultWithoutDiscardingTheFile() throws {
    // A hand-edit can produce the wrong JSON type, not just an unknown string;
    // the `try?` on the String decode must swallow it so one bad field can't
    // reset the file.
    let json = """
      {"appearanceMode":"light","updatesAutomaticallyCheckForUpdates":false,\
      "updatesAutomaticallyDownloadUpdates":false,"chromeTextSize":3}
      """
    let storage = MutableTestStorage(initialData: Data(json.utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.chromeTextSize == .default)
    #expect(settings.global.appearanceMode == .light)
  }

  @Test(.dependencies) func roundTripsExplicitChromeTextSize() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.chromeTextSize = .extraLarge }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.chromeTextSize == .extraLarge)
  }

  @Test(.dependencies) func decodesUnrecognizedHoverFocusModeAsDefaultWithoutDiscardingTheFile() throws {
    // An unknown mode (older build, hand-edit) must fall back by itself rather
    // than throwing, which would reset every other setting in the file.
    let json = """
      {"appearanceMode":"light","updatesAutomaticallyCheckForUpdates":false,\
      "updatesAutomaticallyDownloadUpdates":false,"hoverFocusMode":"someFutureMode"}
      """
    let storage = MutableTestStorage(initialData: Data(json.utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.hoverFocusMode == .never)
    #expect(settings.global.appearanceMode == .light)
  }

  @Test(.dependencies) func decodesMistypedHoverFocusModeAsDefaultWithoutDiscardingTheFile() throws {
    // A hand-edit can produce the wrong JSON type, not just an unknown string;
    // the `try?` on the String decode must swallow it so one bad field can't
    // reset the file.
    let json = """
      {"appearanceMode":"light","updatesAutomaticallyCheckForUpdates":false,\
      "updatesAutomaticallyDownloadUpdates":false,"hoverFocusMode":3}
      """
    let storage = MutableTestStorage(initialData: Data(json.utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.hoverFocusMode == .never)
    #expect(settings.global.appearanceMode == .light)
  }

  @Test(.dependencies) func roundTripsExplicitHoverFocusMode() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.hoverFocusMode = .terminals }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.hoverFocusMode == .terminals)
  }

  @Test func hoverFocusModeRawValuesAreStableAcrossReleases() {
    // The raw values are the on-disk representation; renaming one silently
    // resets every user's choice on the next load.
    #expect(HoverFocusMode.never.rawValue == "never")
    #expect(HoverFocusMode.terminals.rawValue == "terminals")
  }

  @Test(.dependencies) func roundTripsExplicitNotificationRetentionLimit() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.notificationRetentionLimit = .oneThousand }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    #expect(reloaded.global.notificationRetentionLimit == .oneThousand)
  }
}

nonisolated private final class MutableTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private let initialData: Data

  init(initialData: Data) {
    self.initialData = initialData
  }

  var storage: SettingsFileStorage {
    SettingsFileStorage(
      load: { try self.load($0) },
      save: { try self.save($0, $1) }
    )
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    if let data {
      return data
    }
    return initialData
  }

  private func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    self.data = data
  }
}

private struct LegacySettingsFile: Codable {
  var global: LegacyGlobalSettings
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettings: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
}

private struct LegacySettingsFileWithArchiveFlag: Codable {
  var global: LegacyGlobalSettingsWithArchiveFlag
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithArchiveFlag: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var automaticallyArchiveMergedWorktrees: Bool
}

private struct LegacySettingsFileWithSoundToggle: Codable {
  var global: LegacyGlobalSettingsWithSoundToggle
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithSoundToggle: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var notificationSoundEnabled: Bool
}

private struct LegacySettingsFileWithQuitToggle: Codable {
  var global: LegacyGlobalSettingsWithQuitToggle
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithQuitToggle: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var confirmBeforeQuit: Bool
}

private struct LegacySettingsFileWithCloseSurface: Codable {
  var global: LegacyGlobalSettingsWithCloseSurface
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithCloseSurface: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var confirmCloseSurface: Bool
}

private struct SettingsFileWithRawAppVisibility: Codable {
  var global: GlobalSettingsWithRawAppVisibility
  var repositories: [String: RepositorySettings]
}

private struct GlobalSettingsWithRawAppVisibility: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var appVisibility: String
}
