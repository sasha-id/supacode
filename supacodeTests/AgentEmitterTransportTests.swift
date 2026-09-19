import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Runs the generated in-process emitters (Pi, OMP, Hermes) for real against a
/// live signals socket. Their bodies are string literals with no compiler or
/// interpreter behind them at build time, so this is the only check that they
/// parse at all and that the envelope they put on the wire is the one the app
/// parses back.
@MainActor
struct AgentEmitterTransportTests {
  private struct Captured: Sendable {
    let id: String
    let metadata: String
    let surfaceID: UUID
  }

  private struct RunResult: Sendable {
    let status: Int32
    let standardError: String
  }

  // MARK: - Harness

  private static func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "AgentEmitterTransportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Runs off the main actor: the server hops signal dispatch to the main actor,
  /// so blocking it on `waitUntilExit` would deadlock against the emitter's ack.
  private nonisolated static func run(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String]
  ) async -> RunResult {
    await Task.detached {
      let process = Process()
      process.executableURL = URL(filePath: executable)
      process.arguments = arguments
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
      process.standardOutput = FileHandle.nullDevice
      let errors = Pipe()
      process.standardError = errors
      do {
        try process.run()
      } catch {
        return RunResult(status: -1, standardError: "\(error)")
      }
      let errorData = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return RunResult(
        status: process.terminationStatus,
        standardError: String(bytes: errorData, encoding: .utf8) ?? "")
    }.value
  }

  /// Node runs the `.ts` bodies directly via type stripping (22.18+). Absent a
  /// usable Node the extension tests have nothing to execute and stand down;
  /// the Hermes test still covers the shared envelope.
  private nonisolated static var nodeExecutable: String? {
    let searchPaths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    let candidates =
      ["/opt/homebrew/bin/node", "/usr/local/bin/node"] + searchPaths.map { "\($0)/node" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func makeServer() -> AgentHookSocketServer {
    AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
  }

  /// Bridges the server's signal callback into a stream with a watchdog, so a
  /// silent emitter fails the test instead of hanging the suite.
  private func captureSignals(
    _ server: AgentHookSocketServer
  ) -> (AsyncStream<Captured>, Task<Void, Never>) {
    let (signals, continuation) = AsyncStream.makeStream(of: Captured.self)
    server.onContextSignal = { id, metadata, surfaceID in
      continuation.yield(Captured(id: id, metadata: metadata, surfaceID: surfaceID))
    }
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(10))
      continuation.finish()
    }
    return (signals, watchdog)
  }

  /// Loads a generated extension under Node and calls its default export with a
  /// stub host, which is what fires `session_start` on load.
  private func expectExtensionSignalsOverTheSocket(agent: String, indexTs: String) async throws {
    guard let node = Self.nodeExecutable else { return }
    let server = makeServer()
    defer { server.shutdown() }
    let signalPath = try #require(server.signalSocketPath)
    let (signals, watchdog) = captureSignals(server)
    defer { watchdog.cancel() }

    let directory = try Self.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let indexURL = directory.appending(path: "index.ts", directoryHint: .notDirectory)
    try indexTs.write(to: indexURL, atomically: true, encoding: .utf8)

    let surfaceID = UUID()
    let result = await Self.run(
      node,
      [
        "--input-type=module", "-e",
        "const m = await import('file://\(indexURL.path(percentEncoded: false))');"
          + " m.default({ on() {} });",
      ],
      environment: [
        "SUPACODE_SURFACE_ID": surfaceID.uuidString,
        AgentPresenceOSC.socketEnvVar: signalPath,
      ])
    guard result.status == 0 else {
      Issue.record("node rejected the generated \(agent) extension: \(result.standardError)")
      return
    }

    var iterator = signals.makeAsyncIterator()
    let signal = try #require(await iterator.next())
    #expect(signal.id == agent)
    #expect(signal.surfaceID == surfaceID)
    // The pid rides along so the app's liveness sweep can reap a crashed agent.
    #expect(signal.metadata.hasPrefix("event=session_start;pid="))
  }

  // MARK: - Extensions

  @Test func thePiExtensionSignalsOverTheSocket() async throws {
    try await expectExtensionSignalsOverTheSocket(agent: "pi", indexTs: PiExtensionContent.indexTs)
  }

  @Test func theOmpExtensionSignalsOverTheSocket() async throws {
    try await expectExtensionSignalsOverTheSocket(agent: "omp", indexTs: OmpExtensionContent.indexTs)
  }

  // MARK: - Hermes

  @Test func theHermesPluginSignalsOverTheSocket() async throws {
    let server = makeServer()
    defer { server.shutdown() }
    let signalPath = try #require(server.signalSocketPath)
    let (signals, watchdog) = captureSignals(server)
    defer { watchdog.cancel() }

    let directory = try Self.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try HermesPluginContent.module().write(
      to: directory.appending(path: "supacode_presence.py", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8)

    let surfaceID = UUID()
    let result = await Self.run(
      "/usr/bin/python3",
      ["-c", "import supacode_presence as m; m._emit_presence('busy')"],
      environment: [
        "PYTHONPATH": directory.path(percentEncoded: false),
        "PYTHONDONTWRITEBYTECODE": "1",
        "SUPACODE_SURFACE_ID": surfaceID.uuidString,
        AgentPresenceOSC.socketEnvVar: signalPath,
      ])
    guard result.status == 0 else {
      Issue.record("python rejected the generated Hermes module: \(result.standardError)")
      return
    }

    var iterator = signals.makeAsyncIterator()
    let signal = try #require(await iterator.next())
    #expect(signal.id == "hermes")
    #expect(signal.surfaceID == surfaceID)
    #expect(signal.metadata.hasPrefix("event=busy;pid="))
  }

  @Test func theHermesPluginSurvivesAnUnreachableSocket() async throws {
    // The plugin runs inside the agent turn, so a dead socket must degrade to
    // the terminal leg rather than raise out of the hook.
    let directory = try Self.makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try HermesPluginContent.module().write(
      to: directory.appending(path: "supacode_presence.py", directoryHint: .notDirectory),
      atomically: true,
      encoding: .utf8)

    let result = await Self.run(
      "/usr/bin/python3",
      ["-c", "import supacode_presence as m; m._emit_presence('busy'); m._emit_notification('t', 'b')"],
      environment: [
        "PYTHONPATH": directory.path(percentEncoded: false),
        "PYTHONDONTWRITEBYTECODE": "1",
        "SUPACODE_SURFACE_ID": UUID().uuidString,
        AgentPresenceOSC.socketEnvVar: directory.appending(path: "absent.sock").path(percentEncoded: false),
      ])
    #expect(result.status == 0)
    #expect(result.standardError.isEmpty)
  }
}
