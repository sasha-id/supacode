import Darwin
import Foundation
import Testing

@testable import supacode

/// In-process Unix-socket servers exercising the native session probe against
/// the frozen zmx wire shape (`ThirdParty/zmx/src/ipc.zig`).
nonisolated struct ZmxSessionProbeTests {
  private static func temporarySocketPath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("probe-\(UUID().uuidString.prefix(8)).sock").path
  }

  /// Binds a listening socket, serves one connection on a background thread,
  /// and hands the accepted fd to `serve`. The caller owns unlinking.
  private static func listen(
    at path: String,
    serve: @escaping @Sendable (Int32) -> Void
  ) -> Int32 {
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    precondition(server >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
      sunPath.copyBytes(from: Array(path.utf8))
    }
    let bound = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    precondition(bound == 0, "bind failed errno=\(errno)")
    precondition(Darwin.listen(server, 1) == 0)
    Thread.detachNewThread {
      let client = accept(server, nil, nil)
      guard client >= 0 else { return }
      serve(client)
      close(client)
    }
    return server
  }

  private static func message(tag: UInt8, payload: [UInt8]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: ZmxSessionProbe.headerSize)
    bytes[0] = tag
    let length = UInt32(payload.count)
    for index in 0..<4 {
      bytes[1 + index] = UInt8((length >> (8 * UInt32(index))) & 0xFF)
    }
    return bytes + payload
  }

  private static func infoPayload(otherClients: UInt64) -> [UInt8] {
    var payload = [UInt8](repeating: 0, count: ZmxSessionProbe.infoPayloadSize)
    for index in 0..<8 {
      payload[index] = UInt8((otherClients >> (8 * UInt64(index))) & 0xFF)
    }
    return payload
  }

  /// Reads and discards the probe's 8-byte Info request.
  private static func drainRequest(_ client: Int32) {
    var request = [UInt8](repeating: 0, count: ZmxSessionProbe.headerSize)
    var received = 0
    while received < request.count {
      let count = request.withUnsafeMutableBytes { buffer in
        read(client, buffer.baseAddress! + received, buffer.count - received)
      }
      guard count > 0 else { return }
      received += count
    }
  }

  @Test func missingSocketFileReportsDead() {
    #expect(ZmxSessionProbe.probe(socketPath: Self.temporarySocketPath()) == .dead)
  }

  @Test func socketFileWithoutListenerReportsDead() {
    let path = Self.temporarySocketPath()
    defer { unlink(path) }
    // Bind then close: the file survives, nothing listens — a crashed daemon.
    let orphan = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
      sunPath.copyBytes(from: Array(path.utf8))
    }
    _ = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(orphan, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    close(orphan)

    #expect(ZmxSessionProbe.probe(socketPath: path) == .dead)
  }

  @Test func respondingDaemonReportsClientCount() {
    let path = Self.temporarySocketPath()
    let server = Self.listen(at: path) { client in
      Self.drainRequest(client)
      let reply = Self.message(tag: ZmxSessionProbe.infoTag, payload: Self.infoPayload(otherClients: 2))
      _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
    defer {
      close(server)
      unlink(path)
    }

    #expect(ZmxSessionProbe.probe(socketPath: path) == .alive(otherClients: 2))
  }

  @Test func broadcastNoiseBeforeInfoIsSkipped() {
    let path = Self.temporarySocketPath()
    let server = Self.listen(at: path) { client in
      Self.drainRequest(client)
      // A daemon pushes Output broadcasts to every accepted connection.
      let noise = Self.message(tag: 1, payload: Array("prompt$ ".utf8))
      let reply = Self.message(tag: ZmxSessionProbe.infoTag, payload: Self.infoPayload(otherClients: 0))
      let combined = noise + reply
      _ = combined.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
    defer {
      close(server)
      unlink(path)
    }

    #expect(ZmxSessionProbe.probe(socketPath: path) == .alive(otherClients: 0))
  }

  @Test func silentDaemonReportsUnknown() {
    let path = Self.temporarySocketPath()
    // Accepts, then holds the connection open without ever replying — the
    // shape of a daemon stuck in its teardown grace period.
    let gate = DispatchSemaphore(value: 0)
    let server = Self.listen(at: path) { _ in gate.wait() }
    defer {
      gate.signal()
      close(server)
      unlink(path)
    }

    let outcome = ZmxSessionProbe.probe(socketPath: path, timeout: .milliseconds(40))
    #expect(outcome == .unknown)
  }

  @Test func oversizedSocketPathReportsUnknown() {
    let path = "/tmp/" + String(repeating: "x", count: 120)
    #expect(ZmxSessionProbe.probe(socketPath: path) == .unknown)
  }
}
