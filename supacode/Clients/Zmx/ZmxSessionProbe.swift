import Darwin

/// Native probe of a single zmx session daemon over its Unix socket.
///
/// The unexpected-close path must decide spare/kill/reattach while the
/// session's daemon may be mid-teardown, and `zmx ls` blocks on exactly that
/// daemon for its full kill grace period (500ms) besides paying a subprocess
/// spawn and a round-trip to every other live session. One direct connect
/// answers the only question the close path has — is *this* session's daemon
/// still listening, and how many clients does it hold — in microseconds.
///
/// Wire shape mirrors `ThirdParty/zmx/src/ipc.zig`, whose "WIRE PROTOCOL
/// FREEZE" tests pin it: an 8-byte header (tag u8 at byte 0, payload length
/// u32 little-endian at bytes 1-4, 3 padding bytes), `Info` tag 6 with an
/// empty request payload, and a 552-byte `Info` reply carrying the client
/// count (excluding the requester) as a u64 little-endian at offset 0.
nonisolated enum ZmxSessionProbe {
  enum Outcome: Equatable, Sendable {
    /// Definitive no-listener signal: missing socket file or refused connect.
    case dead
    /// The daemon replied; `otherClients` excludes this probe's connection.
    case alive(otherClients: Int)
    /// Ambiguous (wedged daemon, timeout, oversized path); never destroy on it.
    case unknown
  }

  static let headerSize = 8
  static let infoTag: UInt8 = 6
  static let infoPayloadSize = 552
  /// `sockaddr_un.sun_path` capacity including the NUL terminator.
  static let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

  /// Blocking (bounded by `timeout`); call off the main thread.
  static func probe(socketPath: String, timeout: Duration = .milliseconds(100)) -> Outcome {
    let deadline = ContinuousClock.now + timeout
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < sunPathCapacity else { return .unknown }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .unknown }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return .unknown }

    switch connect(fd, path: pathBytes, deadline: deadline) {
    case .dead: return .dead
    case .unknown: return .unknown
    case .connected: break
    }

    // Info request: tag 6, zero-length payload, zeroed header padding.
    var header = [UInt8](repeating: 0, count: headerSize)
    header[0] = infoTag
    guard writeAll(fd, bytes: header, deadline: deadline) else { return .unknown }

    return readInfoReply(fd, deadline: deadline)
  }

  private enum ConnectResult {
    case connected
    case dead
    case unknown
  }

  private static func connect(_ fd: Int32, path: [UInt8], deadline: ContinuousClock.Instant) -> ConnectResult {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
      sunPath.copyBytes(from: path)
    }
    let rc = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if rc == 0 { return .connected }
    switch errno {
    case ENOENT, ECONNREFUSED:
      return .dead
    case EINPROGRESS:
      guard poll(fd, events: POLLOUT, deadline: deadline) else { return .unknown }
      var soError: Int32 = 0
      var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 else { return .unknown }
      switch soError {
      case 0: return .connected
      case ENOENT, ECONNREFUSED: return .dead
      default: return .unknown
      }
    default:
      return .unknown
    }
  }

  private static func writeAll(_ fd: Int32, bytes: [UInt8], deadline: ContinuousClock.Instant) -> Bool {
    var sent = 0
    while sent < bytes.count {
      let n = bytes.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress! + sent, bytes.count - sent)
      }
      if n > 0 {
        sent += n
        continue
      }
      guard errno == EAGAIN || errno == EINTR else { return false }
      guard poll(fd, events: POLLOUT, deadline: deadline) else { return false }
    }
    return true
  }

  /// Reads until an `Info` message arrives, skipping interleaved broadcasts
  /// (a daemon pushes `Output` to every accepted connection, `Init` or not).
  private static func readInfoReply(_ fd: Int32, deadline: ContinuousClock.Instant) -> Outcome {
    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n > 0 {
        buffer.append(contentsOf: chunk[..<n])
        if let outcome = parseInfo(from: &buffer) { return outcome }
        continue
      }
      // EOF or reset mid-handshake is ambiguous, not proof the session died.
      if n == 0 { return .unknown }
      guard errno == EAGAIN || errno == EINTR else { return .unknown }
      guard poll(fd, events: POLLIN, deadline: deadline) else { return .unknown }
    }
  }

  private static func parseInfo(from buffer: inout [UInt8]) -> Outcome? {
    while buffer.count >= headerSize {
      let payloadLength = Int(littleEndianUInt32(buffer, at: 1))
      let messageLength = headerSize + payloadLength
      guard buffer.count >= messageLength else { return nil }
      if buffer[0] == infoTag, payloadLength == infoPayloadSize {
        let clients = littleEndianUInt64(buffer, at: headerSize)
        return .alive(otherClients: Int(clamping: clients))
      }
      buffer.removeFirst(messageLength)
    }
    return nil
  }

  private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { value, index in
      value | (UInt32(bytes[offset + index]) << (8 * index))
    }
  }

  private static func littleEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { value, index in
      value | (UInt64(bytes[offset + index]) << (8 * index))
    }
  }

  /// Waits for `events` until `deadline`; false on timeout or poll failure.
  private static func poll(_ fd: Int32, events: Int32, deadline: ContinuousClock.Instant) -> Bool {
    while true {
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else { return false }
      let milliseconds = Int32(clamping: remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000)
      var pollFD = pollfd(fd: fd, events: Int16(events), revents: 0)
      let rc = Darwin.poll(&pollFD, 1, max(1, milliseconds))
      if rc > 0 { return true }
      if rc == 0 { return false }
      guard errno == EINTR else { return false }
    }
  }
}
