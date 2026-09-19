import ConcurrencyExtras
import Darwin
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentHookSocketServerTests {
  // MARK: - CLI protocol framing.

  @Test func nonJSONPayloadIsRejected() {
    // The socket carries only the CLI control protocol (JSON command / query).
    // Anything that is not a JSON object is dropped.
    let raw = "wt \(UUID().uuidString) \(UUID().uuidString) 1"
    #expect(AgentHookSocketServer.parse(data: Data(raw.utf8)) == nil)
  }

  @Test func emptyInputReturnsNil() {
    #expect(AgentHookSocketServer.parse(data: Data()) == nil)
  }

  @Test func whitespaceOnlyInputReturnsNil() {
    #expect(AgentHookSocketServer.parse(data: Data("   \n  \n  ".utf8)) == nil)
  }

  // MARK: - CLI command message parsing.

  @Test func parsesValidCommandMessage() {
    let json = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .command(let url, _) = message else {
      Issue.record("Expected command message, got \(String(describing: message))")
      return
    }
    #expect(url.scheme == "supacode")
    #expect(url.host() == "worktree")
  }

  @Test func rejectsCommandWithInvalidScheme() {
    let json = #"{"deeplink":"https://example.com"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func rejectsCommandWithMalformedJSON() {
    let json = #"{"not_deeplink":"supacode://test"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  // MARK: - Query message parsing.

  @Test func parsesValidQueryMessage() {
    let json = #"{"query":"repos"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
    #expect(params.isEmpty)
  }

  @Test func parsesQueryMessageWithParams() {
    let json = #"{"query":"tabs","worktreeID":"/tmp/repo"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, let params, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "tabs")
    #expect(params["worktreeID"] == "/tmp/repo")
  }

  @Test func queryTakesPrecedenceOverDeeplink() {
    let json = #"{"query":"repos","deeplink":"supacode://worktree/test"}"#
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .query(let resource, _, _) = message else {
      Issue.record("Expected query message, got \(String(describing: message))")
      return
    }
    #expect(resource == "repos")
  }

  @Test func rejectsJSONWithNeitherQueryNorDeeplink() {
    let json = #"{"foo":"bar"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  // MARK: - Context signal parsing.

  @Test func parsesValidContextSignalMessage() throws {
    let surfaceID = UUID()
    let json = """
      {"signal":"claude","metadata":"event=busy;pid=42","surface_id":"\(surfaceID.uuidString)"}
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .contextSignal(let id, let metadata, let parsedSurfaceID) = message else {
      Issue.record("Expected context signal, got \(String(describing: message))")
      return
    }
    #expect(id == "claude")
    #expect(parsedSurfaceID == surfaceID)
    // The metadata must reach the app byte-identical to the OSC leg's, since
    // both share one parser.
    let signal = try #require(AgentPresenceOSC.parse(id: id, metadata: metadata))
    #expect(signal.eventRawValue == "busy")
    #expect(signal.pid == 42)
  }

  @Test func rejectsContextSignalWithEmptyID() {
    let json = #"{"signal":"","metadata":"event=busy","surface_id":"\#(UUID().uuidString)"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func rejectsContextSignalWithoutMetadata() {
    let json = #"{"signal":"claude","surface_id":"\#(UUID().uuidString)"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func rejectsContextSignalWithUnparsableSurfaceID() {
    // Attribution is the whole point of the envelope: without a usable surface
    // the app has nowhere to route the badge, so the message is dropped, not
    // guessed at.
    let json = #"{"signal":"claude","metadata":"event=busy","surface_id":"not-a-uuid"}"#
    #expect(AgentHookSocketServer.parse(data: Data(json.utf8)) == nil)
  }

  @Test func contextSignalTakesPrecedenceOverQueryAndDeeplink() {
    let json = """
      {"signal":"claude","metadata":"event=busy","surface_id":"\(UUID().uuidString)",\
      "query":"repos","deeplink":"supacode://worktree/test"}
      """
    let message = AgentHookSocketServer.parse(data: Data(json.utf8))

    guard case .contextSignal = message else {
      Issue.record("Expected context signal, got \(String(describing: message))")
      return
    }
  }

  // MARK: - readPayload.

  @Test func readPayloadReturnsNilOnReadError() {
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, _ in
      errno = EIO
      return -1
    }
    #expect(payload == nil)
  }

  @Test func readPayloadReturnsACompleteEnvelopeWithoutWaitingForEOF() {
    // OpenBSD netcat never half-closes, so EOF only arrives once it has given up
    // waiting for the ack. A second read here would be that wait.
    var reads = 0
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, buffer in
      reads += 1
      guard reads == 1 else {
        Issue.record("read past a complete envelope")
        return 0
      }
      return Self.fill(buffer, with: #"{"signal":"claude","metadata":"event=busy"}"#)
    }
    #expect(payload.flatMap { String(bytes: $0, encoding: .utf8) } == #"{"signal":"claude","metadata":"event=busy"}"#)
  }

  @Test func readPayloadKeepsReadingAnEnvelopeSplitAtAClosingBrace() {
    // The first chunk ends in `}` but is only the nested object closing, so it
    // must not be mistaken for the whole message.
    let chunks = [#"{"params":{"a":"b"}"#, #","resource":"tabs"}"#]
    var reads = 0
    let payload = AgentHookSocketServer.readPayload(from: -1) { _, buffer in
      defer { reads += 1 }
      return reads < chunks.count ? Self.fill(buffer, with: chunks[reads]) : 0
    }
    #expect(payload.flatMap { String(bytes: $0, encoding: .utf8) } == chunks.joined())
    #expect(reads == 2)
  }

  private static func fill(_ buffer: UnsafeMutableBufferPointer<UInt8>, with text: String) -> Int {
    let bytes = Array(text.utf8)
    _ = buffer.update(fromContentsOf: bytes)
    return bytes.count
  }

  // MARK: - AgentHookEvent decoding.

  // `AgentHookEvent` is the in-app event type the OSC ingest synthesizes; it is
  // also `Decodable` from this JSON shape for test construction.

  @Test func decodesEventWithRequiredFieldsOnly() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "session_start",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.event == "session_start")
    #expect(event.eventName == .sessionStart)
    #expect(event.agent == "claude")
    #expect(event.surfaceID == surfaceID)
    #expect(event.pid == nil)
    #expect(event.data == nil)
  }

  @Test func decodesEventWithPidTimestampAndOpaqueData() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "notification",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)",
        "pid": 12345,
        "ts": "2026-05-10T12:00:00Z",
        "data": {"title": "Done", "message": "All good"}
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.pid == 12345)
    #expect(event.timestamp != nil)

    struct NotificationPayload: Decodable, Equatable {
      let title: String
      let message: String
    }
    #expect(event.decodeData(NotificationPayload.self) == NotificationPayload(title: "Done", message: "All good"))
  }

  @Test func unknownEventNameKeepsRawStringButHasNilEventName() throws {
    let surfaceID = UUID()
    let json = """
      {
        "event": "future_event_we_dont_know_yet",
        "v": 1,
        "agent": "claude",
        "surface_id": "\(surfaceID.uuidString)"
      }
      """
    let event = try JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))
    #expect(event.event == "future_event_we_dont_know_yet")
    #expect(event.eventName == nil)
  }

  @Test func eventMissingSurfaceIDFailsToDecode() {
    let json = #"{"event":"session_start","agent":"claude"}"#
    #expect((try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil)
  }

  @Test func eventWithMalformedSurfaceUUIDFailsToDecode() {
    let json = #"{"event":"session_start","agent":"claude","surface_id":"not-a-uuid"}"#
    #expect((try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil)
  }

  @Test func eventRejectsNonPositivePid() {
    // `kill(0, 0)` succeeds for the caller's process group and `kill(-N, 0)` for
    // group N, so a pid <= 0 would pin a permanent badge in the liveness sweep.
    for badPid in ["0", "-1", "-12345"] {
      let json = """
        {
          "event": "session_start",
          "agent": "claude",
          "surface_id": "\(UUID().uuidString)",
          "pid": \(badPid)
        }
        """
      #expect(
        (try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8))) == nil,
        "Expected nil for pid=\(badPid)")
    }
  }

  // MARK: - Accept-loop lifecycle.

  @Test func acceptLoopDispatchesCommandAndWritesResponse() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)
    let received = LockIsolated<URL?>(nil)
    server.onCommand = { url, clientFD in
      received.setValue(url)
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }

    let payload = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let response = try #require(await Self.sendAndReceive(path: path, payload: payload))

    #expect(response.contains(#""ok":true"#))
    #expect(received.value?.scheme == "supacode")
    server.shutdown()
  }

  @Test func commandWithoutHandlerGetsNotReadyResponse() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)

    let payload = #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#
    let response = try #require(await Self.sendAndReceive(path: path, payload: payload))

    #expect(response.contains(#""ok":false"#))
    #expect(response.contains("Not ready."))
    server.shutdown()
  }

  // MARK: - The signals-only listener (reverse-forwardable).

  @Test func theSignalsSocketAcceptsContextSignals() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    let signalPath = try #require(server.signalSocketPath)
    let surfaceID = UUID()
    let (signals, continuation) = AsyncStream.makeStream(of: CapturedSignal.self)
    server.onContextSignal = { id, metadata, surface in
      continuation.yield(CapturedSignal(id: id, metadata: metadata, surfaceID: surface))
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(10))
      continuation.finish()
    }
    defer { watchdog.cancel() }

    let payload =
      #"{"signal":"claude","metadata":"event=busy","surface_id":"\#(surfaceID.uuidString)"}"#
    let response = try #require(await Self.sendAndReceive(path: signalPath, payload: payload))
    // Acked before dispatch: a hook is holding up an agent turn and must never
    // wait on app state.
    #expect(response.contains(#""ok":true"#))

    var iterator = signals.makeAsyncIterator()
    let signal = try #require(await iterator.next())
    #expect(signal.id == "claude")
    #expect(signal.metadata == "event=busy")
    #expect(signal.surfaceID == surfaceID)
    server.shutdown()
  }

  @Test func theSignalsSocketRefusesDeeplinksWithoutReachingAHandler() async throws {
    // This is the boundary that makes the socket safe to reverse-forward: the
    // deeplink protocol bypasses confirmation under the default
    // `automatedActionPolicy`, so a remote host must never reach it.
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    let signalPath = try #require(server.signalSocketPath)
    let reachedHandler = LockIsolated(false)
    server.onCommand = { _, clientFD in
      reachedHandler.setValue(true)
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }
    server.onQuery = { _, _, clientFD in
      reachedHandler.setValue(true)
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }

    for payload in [
      #"{"deeplink":"supacode://worktree/%2Ftmp%2Frepo/run"}"#,
      #"{"query":"worktrees"}"#,
    ] {
      let response = try #require(await Self.sendAndReceive(path: signalPath, payload: payload))
      #expect(response.contains(#""ok":false"#))
      #expect(response.contains("agent signals only"))
    }
    #expect(reachedHandler.value == false)
    // The same payloads still work on the control socket.
    let allowed = try #require(
      await Self.sendAndReceive(path: path, payload: #"{"query":"worktrees"}"#))
    #expect(allowed.contains(#""ok":true"#))
    server.shutdown()
  }

  @Test func aSecondInstanceDoesNotStealTheSharedSignalsName() throws {
    // Stealing would silently swallow the first instance's remote presence:
    // its forwards still target the shared path, and signals for surfaces it
    // owns would arrive here and be dropped as unknown.
    let directory = try Self.makeSocketDirectory()
    let shared = "\(directory)/\(AgentHookSocketServer.signalSocketName)"
    let first = AgentHookSocketServer(
      socketPathOverride: "\(directory)/pid-1", contendsForSharedSignalName: true)
    defer { first.shutdown() }
    let second = AgentHookSocketServer(
      socketPathOverride: "\(directory)/pid-2", contendsForSharedSignalName: true)

    #expect(first.signalSocketPath == shared)
    #expect(second.signalSocketPath == "\(directory)/pid-2-signals")

    // The incident this test exists for: the loser's teardown used to unlink the
    // shared name unconditionally, leaving the winner listening on a file no
    // client can address — every agent hook on the machine silently transportless
    // until the app restarted.
    let inodeBefore = try #require(Self.inode(at: shared))
    second.shutdown()
    #expect(Self.inode(at: shared) == inodeBefore)
    #expect(first.signalSocketPath == shared)
  }

  @Test func theOwnerRebindsTheSharedNameAfterItIsUnlinkedUnderneathIt() async throws {
    // The bound descriptor survives an outside `unlink`, so the server keeps
    // accepting at a name that no longer resolves. Nothing observable fails —
    // which is why the owner has to notice and re-bind rather than wait for a
    // report.
    let directory = try Self.makeSocketDirectory()
    let shared = "\(directory)/\(AgentHookSocketServer.signalSocketName)"
    let server = AgentHookSocketServer(
      socketPathOverride: "\(directory)/pid-1", contendsForSharedSignalName: true)
    defer { server.shutdown() }
    #expect(server.signalSocketPath == shared)

    unlink(shared)
    #expect(!FileManager.default.fileExists(atPath: shared))

    // Driven directly; the watchdog runs the same call on a timer.
    server.reclaimSignalNameIfLost()

    #expect(server.signalSocketPath == shared)
    let payload =
      #"{"signal":"claude","metadata":"event=busy","surface_id":"\#(UUID().uuidString)"}"#
    let response = try #require(await Self.sendAndReceive(path: shared, payload: payload))
    #expect(response.contains(#""ok":true"#))
  }

  @Test func theOwnerStandsDownWhenAnotherInstanceHoldsTheSharedName() throws {
    // A successor that legitimately reclaimed the name is answering there. Taking
    // it back would start a tug-of-war, and unlinking its file would strand it the
    // same way this instance was stranded.
    let directory = try Self.makeSocketDirectory()
    let shared = "\(directory)/\(AgentHookSocketServer.signalSocketName)"
    let first = AgentHookSocketServer(
      socketPathOverride: "\(directory)/pid-1", contendsForSharedSignalName: true)
    defer { first.shutdown() }
    #expect(first.signalSocketPath == shared)

    unlink(shared)
    let successor = AgentHookSocketServer(
      socketPathOverride: "\(directory)/pid-2", contendsForSharedSignalName: true)
    defer { successor.shutdown() }
    #expect(successor.signalSocketPath == shared)
    let successorInode = try #require(Self.inode(at: shared))

    first.reclaimSignalNameIfLost()

    #expect(Self.inode(at: shared) == successorInode)
  }

  private static func makeSocketDirectory() throws -> String {
    let directory = "/tmp/supacode-tests/\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    return directory
  }

  /// The inode of the file at `path`, or nil when nothing is there. Ownership of
  /// a socket name is an inode question: a successor that reclaims the name puts
  /// a different file at the same path.
  private static func inode(at path: String) -> ino_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_ino
  }

  @Test func shutdownRemovesBothSockets() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    let signalPath = try #require(server.signalSocketPath)
    #expect(FileManager.default.fileExists(atPath: signalPath))

    server.shutdown()

    #expect(server.signalSocketPath == nil)
    #expect(!FileManager.default.fileExists(atPath: signalPath))
    #expect(await Self.sendAndReceive(path: signalPath, payload: "{}") == nil)
  }

  @Test func prunerReapsAPerInstanceSignalsSocketOfADeadProcess() throws {
    // The CLI ignores both signals names (neither parses as `pid-<pid>`), so the
    // pruner is what reclaims a per-instance one whose owner died. The shared
    // name is never pruned: it carries no pid to test, and a live owner's file
    // is indistinguishable from a stale one here.
    let directory = "/tmp/supacode-tests/\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    let deadPID: Int32 = 999_999
    #expect(kill(deadPID, 0) != 0)
    for name in ["pid-\(deadPID)", "pid-\(deadPID)-signals", "signals"] {
      FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: Data())
    }

    AgentHookSocketServer.pruneStaleSocketFiles(in: directory)

    #expect(!FileManager.default.fileExists(atPath: "\(directory)/pid-\(deadPID)"))
    #expect(!FileManager.default.fileExists(atPath: "\(directory)/pid-\(deadPID)-signals"))
    // The shared name carries no pid, so the pruner must leave it to its owner.
    #expect(FileManager.default.fileExists(atPath: "\(directory)/signals"))
  }

  private struct CapturedSignal {
    var id: String
    var metadata: String
    var surfaceID: UUID
  }

  @Test func shutdownRemovesSocketAndRefusesNewConnections() async throws {
    let path = "/tmp/supacode-tests/\(UUID().uuidString)"
    let server = AgentHookSocketServer(socketPathOverride: path)
    #expect(server.socketPath == path)

    server.shutdown()

    #expect(server.socketPath == nil)
    #expect(!FileManager.default.fileExists(atPath: path))
    let response = await Self.sendAndReceive(path: path, payload: "{}")
    #expect(response == nil)
  }

  @Test func aSenderThatNeverHalfClosesIsStillAcked() async throws {
    // OpenBSD netcat, the default `nc` on Debian and Ubuntu, keeps its write side
    // open after stdin ends. Waiting for its EOF meant timing the read out and
    // closing without an ack, which the hook reads as "not delivered".
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    defer { server.shutdown() }
    let signalPath = try #require(server.signalSocketPath)
    let payload =
      #"{"signal":"claude","metadata":"event=busy","surface_id":"\#(UUID().uuidString)"}"#
    let response = try #require(
      await Self.sendAndReceive(path: signalPath, payload: payload, halfCloses: false))
    #expect(response.contains(#""ok":true"#))
  }

  /// Connects, writes `payload`, half-closes, and reads the response to EOF,
  /// all off the main actor so the server's main-actor dispatch can run while
  /// the client blocks. Returns nil when the connection fails.
  private nonisolated static func sendAndReceive(
    path: String, payload: String, halfCloses: Bool = true
  ) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFD >= 0 else {
          continuation.resume(returning: nil)
          return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
          close(clientFD)
          continuation.resume(returning: nil)
          return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
          pathBytes.withUnsafeBufferPointer { buffer in
            memcpy(sunPath, buffer.baseAddress!, buffer.count)
          }
        }
        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(clientFD, sockaddrPointer, addrLen)
          }
        }
        guard connected == 0 else {
          close(clientFD)
          continuation.resume(returning: nil)
          return
        }
        let bytes = Array(payload.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer in
          write(clientFD, buffer.baseAddress, buffer.count)
        }
        // Half-close so the server's read-to-EOF loop completes while the
        // response can still come back.
        if halfCloses { Darwin.shutdown(clientFD, SHUT_WR) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = chunk.withUnsafeMutableBufferPointer { buffer in
            read(clientFD, buffer.baseAddress, buffer.count)
          }
          guard count > 0 else { break }
          data.append(contentsOf: chunk.prefix(count))
        }
        close(clientFD)
        continuation.resume(returning: String(data: data, encoding: .utf8))
      }
    }
  }

  // MARK: - Stale socket pruning.

  @Test func pruneRemovesDeadEntriesButKeepsUnsignalableAndMalformedOnes() throws {
    let directory = NSTemporaryDirectory() + "supacode-prune-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // pid-1 is launchd: alive but only reachable as EPERM. pid-999999999 is
    // above the pid ceiling, so ESRCH. pid-abc is not a pid file.
    for name in ["pid-1", "pid-999999999", "pid-abc"] {
      #expect(FileManager.default.createFile(atPath: "\(directory)/\(name)", contents: nil))
    }

    AgentHookSocketServer.pruneStaleSocketFiles(in: directory)

    #expect(FileManager.default.fileExists(atPath: "\(directory)/pid-1"))
    #expect(!FileManager.default.fileExists(atPath: "\(directory)/pid-999999999"))
    #expect(FileManager.default.fileExists(atPath: "\(directory)/pid-abc"))
  }
}
