import ConcurrencyExtras
import Darwin
import Foundation
import SupacodeSettingsShared

private nonisolated let socketLogger = SupaLogger("AgentHookSocket")

/// Lightweight Unix domain socket server for the Supacode CLI control protocol
/// and agent presence.
///
/// Three message formats are supported, all JSON objects:
/// - **Command**: a `"deeplink"` key wrapping a `supacode://` URL.
/// - **Query**: a `"query"` key and optional parameters.
/// - **Context signal**: a `"signal"` key with `"metadata"` and `"surface_id"` —
///   the agent presence / notify wire (see `AgentPresenceOSC`). It is the only
///   transport a managed surface uses, precisely because it leaves the agent's
///   terminal alone: a hook that cannot reach the socket drops the signal rather
///   than writing OSC into a tty its agent is mid-render on. That makes this
///   listener's availability the whole presence story, which is why the name it
///   is bound to is defended below rather than merely bound once.
///
/// Two listeners are bound, and the difference is a security boundary, not a
/// convenience. `socketPath` speaks the full protocol and must stay local-only:
/// `AutomatedActionPolicy.cliOnly` (the default) treats socket-sourced commands
/// as trusted, so anything that can reach it can run worktree scripts, delete
/// worktrees and type into tabs without a confirmation prompt.
/// `signalSocketPath` accepts context signals and refuses commands and queries
/// outright, which is what makes it safe to reverse-forward to a remote host
/// (see `ZmxAttach.socketPrelude`). Never forward `socketPath`.
@MainActor
final class AgentHookSocketServer {
  private(set) var socketPath: String?

  /// Signals-only listener, reverse-forwarded to remote hosts so their agent
  /// hooks reach presence without writing OSC into the agent's own tty.
  private(set) var signalSocketPath: String?

  /// Inode of the file `signalSocketPath` named when this instance bound it.
  /// Ownership is proved by inode rather than by path: a successor that reclaims
  /// the shared name binds a *different* file at the same path, and unlinking
  /// that one is exactly the defect the ownership checks exist to prevent.
  private var signalSocketInode: ino_t?

  /// Shared name for the signals listener, and the suffix of the per-instance
  /// fallback. Deliberately not `pid-<pid>`-parseable, so the CLI's socket
  /// discovery keeps ignoring both.
  nonisolated static let signalSocketName = "signals"
  nonisolated static let signalSocketSuffix = "-signals"

  /// Cancellation flag for the accept-loop thread; shared by reference so the
  /// thread never retains `self`.
  private let listenStopped = LockIsolated(false)

  /// The same for the signals listener alone, so a re-bind can retire just that
  /// accept loop and leave the control socket running. Replaced wholesale
  /// rather than reset: the retired thread keeps the old instance and stops,
  /// while the new thread watches the new one.
  private var signalListenStopped = LockIsolated(false)

  /// Watches the shared signals name for disappearing underneath us. Only an
  /// instance holding the *shared* name runs one — a per-instance name is
  /// derived from this process's pid, so nothing else can take it. A `Task`
  /// rather than a `Timer` because `deinit` has to be able to stop it, and a
  /// non-Sendable `Timer` cannot be touched from there.
  private var signalNameWatchdog: Task<Void, Never>?

  /// How often the watchdog compares the name on disk against what it bound.
  /// A `stat` every few seconds is far cheaper than the failure it catches,
  /// where every agent hook on the machine loses its transport until restart.
  private static let signalNameWatchdogInterval: TimeInterval = 5
  /// Deeplink URL received from the CLI. Second parameter is the client FD for response.
  var onCommand: ((URL, Int32) -> Void)?
  /// Query received from the CLI. Parameters: resource name, extra params, client FD for response.
  var onQuery: ((String, [String: String], Int32) -> Void)?
  /// Presence / notify signal from a local agent hook. Parameters: context id,
  /// raw `key=value` metadata, attributed surface. Fire-and-forget — the client
  /// is already acked by the time this fires, so handlers must not block.
  var onContextSignal: ((String, String, UUID) -> Void)?

  /// `socketPathOverride` lets tests bind a unique path; the default is the
  /// pid-derived path the CLI discovers.
  ///
  /// `contendsForSharedSignalName` is the opt-in for the tests that exercise the
  /// shared-name handover. An overridden path otherwise stays on its per-instance
  /// signals name, so unrelated tests sharing a directory never fight over one
  /// file — which also means the contention path needs an explicit way in.
  init(socketPathOverride: String? = nil, contendsForSharedSignalName: Bool = false) {
    let directory: String
    let path: String
    if let socketPathOverride {
      path = socketPathOverride
      directory = (socketPathOverride as NSString).deletingLastPathComponent
    } else {
      let uid = getuid()
      let pid = ProcessInfo.processInfo.processIdentifier
      // A test host is a real second instance — every bundle sets `TEST_HOST` to
      // the app, and parallel testing launches several at once. Pointing them at
      // the live directory lets them contend for, and tear down, the running
      // app's sockets; giving them their own is the enforceable form of "don't
      // run a second instance against someone's live machine".
      directory =
        ProcessInfo.processInfo.isRunningUnitTests
        ? "/tmp/supacode-\(uid)-tests" : "/tmp/supacode-\(uid)"
      path = "\(directory)/pid-\(pid)"
    }

    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      socketLogger.warning("Failed to create socket directory: \(error)")
      return
    }

    if socketPathOverride == nil {
      Self.pruneStaleSocketFiles(in: directory)
    }
    unlink(path)
    guard startListening(path: path) else { return }
    socketPath = path
    let perInstanceSignalPath = path + Self.signalSocketSuffix
    // The shared name exists for restart recovery — surfaces that outlive an app
    // restart keep reaching presence through it. A test host has no sessions to
    // recover, so it never competes for it.
    let wantsSharedName =
      contendsForSharedSignalName
      || (socketPathOverride == nil && !ProcessInfo.processInfo.isRunningUnitTests)
    bindSignalListener(
      preferred: wantsSharedName
        ? "\(directory)/\(Self.signalSocketName)" : perInstanceSignalPath,
      fallback: perInstanceSignalPath
    )
  }

  /// Binds the signals-only listener, preferring the instance-independent
  /// `signals` name. A remote surface's reconnect loop bakes its `-R` target
  /// when the surface spawns, so a pid-derived name would leave every surface
  /// that outlived an app restart forwarding to a socket nobody owns. A second
  /// concurrent instance must not simply steal the shared name either — the
  /// first instance's remote signals would then be delivered here and dropped
  /// as unknown surfaces — so a live listener sends us to the per-instance name
  /// and only the first instance gets restart recovery.
  private func bindSignalListener(preferred: String, fallback: String) {
    let path = Self.isLiveSocket(path: preferred) ? fallback : preferred
    // Safe for either outcome: `isLiveSocket` proved nothing answers at
    // `preferred`, and `fallback` is derived from this process's own pid, so
    // only a crashed predecessor sharing our pid could have left it behind.
    unlink(path)
    guard startListening(path: path, signalsOnly: true) else { return }
    signalSocketPath = path
    signalSocketInode = Self.inode(at: path)
    if path != fallback { startSignalNameWatchdog() }
  }

  /// True unless it can be *proved* that nothing is listening at `path`.
  ///
  /// Deliberately fails closed. The caller reclaims a name this reports free,
  /// and reclaiming a name whose owner is merely busy strands that owner on a
  /// socket no client can address. Only two errno values prove a free name:
  /// `ENOENT` (no such name) and a `ECONNREFUSED` that persists — a socket file
  /// outliving the process that bound it refuses every time, whereas a live
  /// listener whose backlog is momentarily full refuses one connect and accepts
  /// the next. Every other failure (a sandbox's `EPERM`, `EINTR`, a path too
  /// long to express) is ambiguous and reads as live.
  private nonisolated static func isLiveSocket(path: String) -> Bool {
    // Four probes at 75ms cover a backlog that drains within one poll interval
    // (200ms) without making startup wait noticeably on a genuinely dead name.
    for attempt in 0..<4 {
      if attempt > 0 { usleep(75_000) }
      let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
      guard probeFD >= 0 else { return true }
      defer { close(probeFD) }
      var failure: Int32 = 0
      let connected = withUnixAddress(path: path) { addr, addrLen in
        let result = connect(probeFD, addr, addrLen)
        failure = result == 0 ? 0 : errno
        return result == 0
      }
      guard let connected else { return true }
      if connected { return true }
      if failure == ENOENT { return false }
      guard failure == ECONNREFUSED else { return true }
    }
    return false
  }

  /// The inode of the socket file at `path`, or nil when nothing is there.
  private nonisolated static func inode(at path: String) -> ino_t? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return info.st_ino
  }

  /// Removes `signalSocketPath` only while the file there is still the one this
  /// instance bound. A successor that reclaimed the name left a different inode,
  /// and unlinking that would strand *it* the same way.
  private nonisolated static func unlinkOwnedSignalSocket(
    path: String?, inode: ino_t?
  ) {
    guard let path, let inode, Self.inode(at: path) == inode else { return }
    unlink(path)
  }

  /// Re-binds the shared signals name when it stops pointing at this instance's
  /// socket. The listener's file descriptor survives an outside `unlink`, so
  /// without this the app goes on accepting connections at a name no client can
  /// reach — and every agent hook that dials it loses its transport for the rest
  /// of the app's life. Idempotent; the watchdog calls it on a timer.
  func reclaimSignalNameIfLost() {
    guard let path = signalSocketPath, let inode = signalSocketInode else { return }
    guard Self.inode(at: path) != inode else { return }
    guard !Self.isLiveSocket(path: path) else {
      // Somebody else is answering there now. Taking it back would start a
      // tug-of-war, and its signals for our surfaces are already lost; say so
      // once per tick rather than fight.
      socketLogger.warning("Signals socket \(path) was taken over by another instance")
      return
    }
    socketLogger.warning("Signals socket \(path) disappeared; rebinding")
    signalListenStopped.setValue(true)
    signalListenStopped = LockIsolated(false)
    unlink(path)
    guard startListening(path: path, signalsOnly: true) else {
      signalSocketPath = nil
      signalSocketInode = nil
      stopSignalNameWatchdog()
      return
    }
    signalSocketInode = Self.inode(at: path)
  }

  private func startSignalNameWatchdog() {
    stopSignalNameWatchdog()
    signalNameWatchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.signalNameWatchdogInterval))
        guard !Task.isCancelled, let self else { return }
        reclaimSignalNameIfLost()
      }
    }
  }

  private func stopSignalNameWatchdog() {
    signalNameWatchdog?.cancel()
    signalNameWatchdog = nil
  }

  /// Removes socket files left behind by processes that are no longer running.
  nonisolated static func pruneStaleSocketFiles(in directory: String) {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(atPath: directory)
    else { return }
    for entry in entries {
      // `pid-<pid>` is the control socket; `pid-<pid>-signals` is the
      // per-instance signals listener a second concurrent instance falls back
      // to. Both die with their process, so both are prunable by the same pid.
      guard entry.hasPrefix("pid-") else { continue }
      var digits = entry.dropFirst(4)
      if digits.hasSuffix(signalSocketSuffix) {
        digits = digits.dropLast(signalSocketSuffix.count)
      }
      guard let pid = Int32(digits) else { continue }
      // Only ESRCH proves the process is gone; EPERM means it exists but
      // cannot be signaled (e.g. a sandboxed or differently-owned process).
      // Mirrors `ProcessLiveness.isRunning` in the CLI and
      // `AgentPresenceFeature.isAlive`; keep in sync.
      let probeResult = kill(pid, 0)
      let probeErrno = errno
      guard probeResult != 0, probeErrno == ESRCH else { continue }
      let stalePath = "\(directory)/\(entry)"
      guard unlink(stalePath) == 0 else {
        socketLogger.error("Failed to prune stale socket \(entry): errno \(errno)")
        continue
      }
      socketLogger.info("Pruned stale socket: \(entry)")
    }
  }

  deinit {
    listenStopped.setValue(true)
    signalListenStopped.setValue(true)
    signalNameWatchdog?.cancel()
    if let socketPath {
      unlink(socketPath)
    }
    Self.unlinkOwnedSignalSocket(path: signalSocketPath, inode: signalSocketInode)
  }

  func shutdown() {
    listenStopped.setValue(true)
    signalListenStopped.setValue(true)
    stopSignalNameWatchdog()
    // A connection accepted in the final poll window must get "Not ready."
    // instead of running against state the owner is tearing down.
    onCommand = nil
    onQuery = nil
    onContextSignal = nil
    if let socketPath {
      unlink(socketPath)
    }
    socketPath = nil
    Self.unlinkOwnedSignalSocket(path: signalSocketPath, inode: signalSocketInode)
    signalSocketPath = nil
    signalSocketInode = nil
  }

  // MARK: - Socket lifecycle.

  @discardableResult
  private func startListening(path: String, signalsOnly: Bool = false) -> Bool {
    let socketFD = Self.createSocket(path: path)
    guard socketFD >= 0 else { return false }

    // The accept loop blocks in poll(), so it runs on a dedicated thread: on
    // the cooperative pool it would pin a thread, and under the test main
    // serial executor it would starve the main thread outright. The thread
    // captures the stop flag, never `self`, so deinit stays reachable.
    let stopped = signalsOnly ? signalListenStopped : listenStopped
    // Captured here so the accept thread can tell "the name still points at the
    // socket I bound" from "somebody else rebound it" without reaching back
    // into main-actor state.
    let boundInode = Self.inode(at: path)
    let thread = Thread { [weak self] in
      socketLogger.info("Listening on \(path)")
      defer { close(socketFD) }

      while !stopped.value {
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 200)
        if ready < 0 {
          guard errno == EINTR else {
            socketLogger.warning("poll() failed: \(String(cString: strerror(errno)))")
            // Remove the advertised path so the CLI sees "not running"
            // instead of a confusing refused connection, and stop new
            // terminals from exporting a dead socket path. The signals name can
            // be shared, so it only goes when it is still ours.
            if signalsOnly {
              Self.unlinkOwnedSignalSocket(path: path, inode: boundInode)
            } else {
              unlink(path)
            }
            Task { @MainActor [weak self] in
              if signalsOnly {
                self?.signalSocketPath = nil
                self?.signalSocketInode = nil
                self?.stopSignalNameWatchdog()
              } else {
                self?.socketPath = nil
              }
            }
            break
          }
          continue
        }
        guard ready > 0 else { continue }

        // Every hook on the machine shares the signals listener and gives up on
        // it after a second, so one stalled sender must not hold the loop longer.
        let receiveTimeoutSeconds = signalsOnly ? 1 : 5
        guard
          let message = Self.acceptAndParse(
            socketFD: socketFD, receiveTimeoutSeconds: receiveTimeoutSeconds)
        else {
          continue
        }

        Task { @MainActor [weak self] in
          Self.dispatch(message: message, to: self, signalsOnly: signalsOnly)
        }
      }
    }
    thread.name = "supacode.agent-hook-socket"
    thread.start()
    return true
  }

  /// Routes an accepted message to the server's handlers, answering "Not
  /// ready." when the server died or has no handler installed yet.
  ///
  /// `signalsOnly` marks the reverse-forwardable listener: commands and queries
  /// are refused there without ever reaching a handler, so reaching a remote
  /// host's forwarded socket buys no access to the CLI control protocol. What it
  /// does grant is the ability to post presence and notifications for a known
  /// surface id, the same authority an OSC written to that surface's tty has.
  private static func dispatch(
    message: Message, to server: AgentHookSocketServer?, signalsOnly: Bool
  ) {
    if signalsOnly {
      switch message {
      case .command(_, let clientFD), .query(_, _, let clientFD):
        socketLogger.warning("Refused a control message on the signals-only socket")
        sendCommandResponse(
          clientFD: clientFD, ok: false, error: "This socket accepts agent signals only.")
        return
      case .contextSignal:
        break
      }
    }
    switch message {
    case .command(let deeplinkURL, let clientFD):
      guard let handler = server?.onCommand else {
        sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
        return
      }
      handler(deeplinkURL, clientFD)
    case .query(let resource, let params, let clientFD):
      guard let handler = server?.onQuery else {
        sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
        return
      }
      handler(resource, params, clientFD)
    case .contextSignal(let id, let metadata, let surfaceID):
      server?.onContextSignal?(id, metadata, surfaceID)
    }
  }

  /// Writes all bytes to an FD, handling partial writes. Logs and
  /// returns silently on write failure.
  private nonisolated static func writeAll(to fileDescriptor: Int32, data: Data) {
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var totalWritten = 0
      while totalWritten < data.count {
        let written = write(
          fileDescriptor, base.advanced(by: totalWritten), data.count - totalWritten)
        if written < 0 {
          guard errno == EINTR else {
            socketLogger.warning("write() failed: \(String(cString: strerror(errno)))")
            return
          }
          continue
        }
        guard written > 0 else { return }
        totalWritten += written
      }
    }
  }

  /// Marks a descriptor close-on-exec so child processes (spawned terminal
  /// shells) never inherit it. Logs and continues on the near-impossible
  /// failure: a fresh fd that can't take the flag is harmless once the
  /// response path also `shutdown(SHUT_WR)`s.
  nonisolated static func setCloseOnExec(_ fileDescriptor: Int32) {
    let flags = fcntl(fileDescriptor, F_GETFD)
    guard flags != -1 else {
      socketLogger.warning("fcntl(F_GETFD) failed: \(String(cString: strerror(errno)))")
      return
    }
    guard fcntl(fileDescriptor, F_SETFD, flags | FD_CLOEXEC) != -1 else {
      socketLogger.warning("fcntl(F_SETFD) failed: \(String(cString: strerror(errno)))")
      return
    }
  }

  /// Disables SIGPIPE for this socket so a deferred write to a client that has
  /// already disconnected returns `EPIPE` (logged + swallowed by `writeAll`)
  /// instead of terminating the process.
  private nonisolated static func setNoSIGPIPE(_ fileDescriptor: Int32) {
    var enabled: Int32 = 1
    guard
      setsockopt(
        fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      socketLogger.warning("setsockopt(SO_NOSIGPIPE) failed: \(String(cString: strerror(errno)))")
      return
    }
  }

  /// Half-closes the write side before closing so the CLI's read-until-EOF
  /// loop unblocks immediately, even if a forked shell still holds an
  /// inherited dup of the socket: `shutdown` acts on the shared socket
  /// object, `close` only drops this fd's reference (issue #529).
  private nonisolated static func shutdownAndClose(_ clientFD: Int32) {
    Darwin.shutdown(clientFD, SHUT_WR)
    close(clientFD)
  }

  // MARK: - Socket creation (nonisolated).

  /// Fills a `sockaddr_un` for `path` and runs `body` against it. Returns nil
  /// when the path does not fit `sun_path`, which callers must treat as a hard
  /// failure rather than a falsy result.
  private nonisolated static func withUnixAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
  ) -> T? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
    return withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, addrLen) }
    }
  }

  private nonisolated static func createSocket(path: String) -> Int32 {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      socketLogger.warning("socket() failed: \(String(cString: strerror(errno)))")
      return -1
    }
    // Keep the control socket out of spawned shells' fd tables.
    setCloseOnExec(socketFD)

    let bindResult = withUnixAddress(path: path) { addr, addrLen in
      bind(socketFD, addr, addrLen)
    }
    guard let bindResult else {
      socketLogger.warning("Socket path too long: \(path)")
      close(socketFD)
      return -1
    }
    guard bindResult == 0 else {
      socketLogger.warning("bind() failed: \(String(cString: strerror(errno)))")
      close(socketFD)
      return -1
    }

    // Every agent hook on the machine dials the signals listener, and a full
    // backlog refuses a connect exactly the way a dead socket does — which is
    // what a second instance's liveness probe reads as a free name. Depth costs
    // nothing here and keeps that misreading rare.
    guard listen(socketFD, 64) == 0 else {
      socketLogger.warning("listen() failed: \(String(cString: strerror(errno)))")
      close(socketFD)
      return -1
    }

    return socketFD
  }

  // MARK: - Connection handling (nonisolated).

  /// Maximum payload size (64 KB) to prevent unbounded memory growth.
  private nonisolated static let maxPayloadSize = 65_536

  nonisolated enum Message: Sendable {
    /// CLI command with the client FD kept open for writing a response.
    case command(deeplinkURL: URL, clientFD: Int32)
    /// CLI query with the client FD kept open for writing data back.
    case query(resource: String, params: [String: String], clientFD: Int32)
    /// Presence / notify signal from a local agent hook. Acked before dispatch,
    /// so the FD is already closed by the time the handler runs: a hook must
    /// never block on app state.
    case contextSignal(id: String, metadata: String, surfaceID: UUID)
  }

  /// Writes a JSON response with data to a client and closes the FD.
  nonisolated static func sendQueryResponse(clientFD: Int32, data: [[String: String]]) {
    let json: [String: Any] = ["ok": true, "data": data]
    guard let encoded = try? JSONSerialization.data(withJSONObject: json) else {
      socketLogger.warning("Failed to encode query response")
      writeAll(
        to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
      shutdownAndClose(clientFD)
      return
    }
    writeAll(to: clientFD, data: encoded)
    shutdownAndClose(clientFD)
  }

  /// Writes a JSON response to a command client and closes the FD. `resourceID`
  /// is echoed as `id` so creation commands can print the created resource.
  nonisolated static func sendCommandResponse(
    clientFD: Int32, ok succeeded: Bool, error: String? = nil, resourceID: String? = nil
  ) {
    var json: [String: Any] = ["ok": succeeded]
    if let error { json["error"] = error }
    if let resourceID { json["id"] = resourceID }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else {
      socketLogger.warning("Failed to encode command response")
      writeAll(
        to: clientFD, data: Data("{\"ok\":false,\"error\":\"Internal encoding error.\"}".utf8))
      shutdownAndClose(clientFD)
      return
    }
    writeAll(to: clientFD, data: data)
    shutdownAndClose(clientFD)
  }

  private nonisolated static func acceptAndParse(
    socketFD: Int32, receiveTimeoutSeconds: Int
  ) -> Message? {
    let clientFD = accept(socketFD, nil, nil)
    guard clientFD >= 0 else {
      let err = errno
      if err != EAGAIN, err != EWOULDBLOCK {
        socketLogger.warning("accept() failed: \(String(cString: strerror(err)))")
      }
      return nil
    }

    // A spawned terminal shell must not inherit this connection's fd, or it
    // keeps the write end open and the CLI never sees EOF (issue #529).
    setCloseOnExec(clientFD)
    // Completion-based acks hold the connection open for the whole operation, so
    // a write to a CLI that already disconnected must not raise SIGPIPE.
    setNoSIGPIPE(clientFD)

    // One deadline for the whole payload, so a misbehaving client cannot block the
    // accept loop by trickling bytes under a per-read timeout.
    let deadline = ContinuousClock.now + .seconds(receiveTimeoutSeconds)
    guard let data = readPayload(from: clientFD, deadline: deadline) else {
      shutdownAndClose(clientFD)
      return nil
    }

    guard let message = parse(data: data) else {
      // If the payload looks like a JSON CLI message, send an error
      // response so the CLI does not hang waiting for a reply.
      if data.first == UInt8(ascii: "{") {
        sendCommandResponse(clientFD: clientFD, ok: false, error: "Malformed request.")
      } else {
        shutdownAndClose(clientFD)
      }
      return nil
    }

    // Command/query messages keep the FD open so the handler can write a response.
    // A context signal is acked here instead: the hook that sent it is holding up
    // an agent turn, so it must never wait on app state.
    switch message {
    case .command(let url, _):
      return .command(deeplinkURL: url, clientFD: clientFD)
    case .query(let resource, let params, _):
      return .query(resource: resource, params: params, clientFD: clientFD)
    case .contextSignal:
      sendCommandResponse(clientFD: clientFD, ok: true)
      return message
    }
  }

  /// Reads one message: to EOF, or until the bytes held form a complete envelope.
  /// Not every client half-closes after writing (OpenBSD netcat keeps its write
  /// side open until it exits), and one that does not would otherwise get its ack
  /// only after it had stopped waiting for it.
  nonisolated static func readPayload(
    from clientFD: Int32,
    deadline: ContinuousClock.Instant? = nil,
    readChunk: (Int32, UnsafeMutableBufferPointer<UInt8>) -> Int = { fileDescriptor, buffer in
      guard let baseAddress = buffer.baseAddress else { return 0 }
      return Darwin.read(fileDescriptor, baseAddress, buffer.count)
    }
  ) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      if let deadline, !setReceiveTimeout(clientFD, until: deadline) { return nil }
      let bytesRead = buffer.withUnsafeMutableBufferPointer { buffer in
        readChunk(clientFD, buffer)
      }
      if bytesRead < 0 {
        let err = errno
        socketLogger.warning("read() failed (\(err)): \(String(cString: strerror(err)))")
        return nil
      }
      if bytesRead == 0 { return data }
      data.append(contentsOf: buffer.prefix(bytesRead))
      if data.count > maxPayloadSize {
        socketLogger.warning("Payload exceeded \(maxPayloadSize) bytes, dropping connection")
        return nil
      }
      if isCompleteEnvelope(data) { return data }
    }
  }

  /// Every message on this socket is a single JSON object, and a strict prefix of
  /// one never parses as one, so bytes that parse are the whole message.
  private nonisolated static func isCompleteEnvelope(_ data: Data) -> Bool {
    let closesAnObject =
      data.last { !($0 == 0x20 || (0x09...0x0D).contains($0)) } == UInt8(ascii: "}")
    guard closesAnObject else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
  }

  /// Arms the read timeout with whatever is left until `deadline`; false once it
  /// has passed.
  private nonisolated static func setReceiveTimeout(
    _ clientFD: Int32, until deadline: ContinuousClock.Instant
  ) -> Bool {
    guard deadline > .now else {
      socketLogger.warning("Client did not finish its payload in time, dropping connection")
      return false
    }
    // A zero timeval means "block forever", so never round the remainder down to it.
    let remaining = max(deadline - .now, .milliseconds(1))
    let (seconds, attoseconds) = remaining.components
    var timeout = timeval(
      tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    guard
      setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        == 0
    else {
      socketLogger.warning("setsockopt(SO_RCVTIMEO) failed: \(String(cString: strerror(errno)))")
      return false
    }
    return true
  }

  nonisolated static func parse(data: Data) -> Message? {
    guard let rawString = String(data: data, encoding: .utf8) else {
      socketLogger.warning("Dropped non-UTF8 CLI payload (\(data.count) bytes)")
      return nil
    }
    let raw = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else {
      socketLogger.debug("Dropped empty CLI payload")
      return nil
    }
    // Every message on this socket is a JSON object (command, query or signal).
    guard raw.hasPrefix("{") else {
      socketLogger.debug("Dropped non-JSON socket payload")
      return nil
    }
    return parseJSONMessage(data: data)
  }

  /// Parses a JSON message into a signal, query or command. The placeholder
  /// `clientFD` of `-1` is replaced with the real FD in `acceptAndParse`.
  private nonisolated static func parseJSONMessage(data: Data) -> Message? {
    guard let request = SocketCommandRequest(data: data) else {
      socketLogger.warning("Failed to decode CLI message payload")
      return nil
    }
    switch request {
    case .contextSignal(let id, let metadata, let surfaceID):
      return .contextSignal(id: id, metadata: metadata, surfaceID: surfaceID)
    case .query(let resource, let params):
      return .query(resource: resource, params: params, clientFD: -1)
    case .command(let deeplink, _):
      guard let url = URL(string: deeplink), url.scheme == "supacode" else {
        socketLogger.warning("Invalid CLI deeplink URL: \(deeplink)")
        return nil
      }
      return .command(deeplinkURL: url, clientFD: -1)
    }
  }
}

/// An agent presence/activity event. Built by the OSC ingest from a verified
/// presence signal (memberwise init, attributed to the receiving surface), and
/// also `Decodable` from the legacy JSON envelope shape below for test
/// construction. `surface_id` is the only scope field; tab and worktree are
/// derived app-side from the current terminal topology so a moved/split surface
/// never carries stale attribution.
///
/// JSON shape (the Decodable contract):
/// ```json
/// {
///   "event": "session_start",   // discriminator + event name (required)
///   "v": 1,                     // protocol version (required)
///   "agent": "claude",          // SkillAgent rawValue (required)
///   "surface_id": "<UUID>",     // required
///   "pid": 12345,               // optional, agent process pid
///   "ts": "<ISO8601>",          // optional, sender clock
///   "data": { ... }             // optional, event-specific
/// }
/// ```
nonisolated struct AgentHookEvent: Equatable, Sendable, Decodable {
  /// Known event names. Stored as raw `String` so an unknown event from a newer
  /// emitter / older app doesn't drop; handlers can ignore them.
  enum EventName: String, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case busy
    case awaitingInput = "awaiting_input"
    case idle
    case notification
    /// Turn ended in an API / connection error. See `AgentPresenceFeature.Activity`
    /// for how long the resulting state sticks around.
    case error
    /// Context compaction started.
    case compacting
  }

  let version: Int
  let agent: String
  let event: String
  let surfaceID: UUID
  let pid: pid_t?
  let timestamp: Date?
  /// Event-specific payload preserved as opaque JSON. Handlers decode with
  /// their own typed shape via `decodeData(_:)`, keeping this layer decoupled
  /// from per-event payload schemas.
  let data: JSONValue?

  /// Convenience: the event name as a known case, or nil for an unrecognized event.
  var eventName: EventName? { EventName(rawValue: event) }

  /// Decode the per-event `data` payload into a concrete type. Returns nil
  /// when `data` is missing. Returns nil and logs a warning when `data` is
  /// present but fails to decode against `T`; silent nil there would make a
  /// shape mismatch invisible to handlers.
  func decodeData<T: Decodable>(_ type: T.Type = T.self) -> T? {
    guard let data else { return nil }
    do {
      let bytes = try JSONEncoder().encode(data)
      return try JSONDecoder().decode(type, from: bytes)
    } catch {
      socketLogger.warning("Failed to decode \(event) data as \(type): \(error)")
      return nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case event, agent, pid, data
    case version = "v"
    case surfaceID = "surface_id"
    case timestamp = "ts"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let event = try container.decode(String.self, forKey: .event)
    guard !event.isEmpty else {
      throw DecodingError.dataCorruptedError(
        forKey: .event, in: container, debugDescription: "`event` must be non-empty.")
    }
    self.event = event
    self.surfaceID = try Self.decodeUUID(from: container, forKey: .surfaceID)
    self.agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? "unknown"
    self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    if let rawPid = try container.decodeIfPresent(Int.self, forKey: .pid) {
      // Reject 0 and negatives: `kill(0, 0)` succeeds for the caller's
      // process group and `kill(-N, 0)` for group N, both of which would
      // pin a permanent badge in the liveness sweep on a buggy hook (e.g.
      // `pid:$$` from a subshell that recycled).
      guard let bounded = pid_t(exactly: rawPid), bounded > 0 else {
        throw DecodingError.dataCorruptedError(
          forKey: .pid, in: container,
          debugDescription: "`pid` \(rawPid) is not a positive pid_t value.")
      }
      self.pid = bounded
    } else {
      self.pid = nil
    }
    if let rawTimestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) {
      self.timestamp = try? Date(rawTimestamp, strategy: .iso8601)
    } else {
      self.timestamp = nil
    }
    self.data = try container.decodeIfPresent(JSONValue.self, forKey: .data)
  }

  /// Memberwise init for synthesizing events from sources other than the JSON
  /// wire. The OSC presence path uses it: attribution is by the receiving
  /// surface and there is no remote pid, so `pid` defaults to nil.
  init(
    version: Int = 1,
    agent: String,
    event: String,
    surfaceID: UUID,
    pid: pid_t? = nil,
    timestamp: Date? = nil,
    data: JSONValue? = nil
  ) {
    self.version = version
    self.agent = agent
    self.event = event
    self.surfaceID = surfaceID
    // Mirror the Decodable validation: a non-positive pid would let `kill(0/-N, 0)`
    // match the caller's process group and pin a permanent badge.
    if let pid, pid <= 0 {
      socketLogger.warning("Clamped non-positive pid \(pid) to nil in AgentHookEvent(agent: \(agent)).")
      self.pid = nil
    } else {
      self.pid = pid
    }
    self.timestamp = timestamp
    self.data = data
  }

  private static func decodeUUID(
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys
  ) throws -> UUID {
    let raw = try container.decode(String.self, forKey: key)
    guard let uuid = UUID(uuidString: raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: container,
        debugDescription: "`\(key.stringValue)` is not a valid UUID: \(raw).")
    }
    return uuid
  }
}

/// Parsed socket payload: an agent context signal, a deeplink command, or a
/// query with params.
private nonisolated enum SocketCommandRequest {
  case command(deeplink: String, params: [String: String])
  case query(resource: String, params: [String: String])
  case contextSignal(id: String, metadata: String, surfaceID: UUID)

  init?(data: Data) {
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    // A `signal` key routes to the presence parser exclusively: a malformed
    // signal must not fall through to query/command and log two misleading
    // warnings instead of one.
    if let id = dict[AgentPresenceOSC.signalField] as? String {
      guard !id.isEmpty,
        let metadata = dict[AgentPresenceOSC.metadataField] as? String,
        let rawSurfaceID = dict[AgentPresenceOSC.surfaceIDField] as? String,
        let surfaceID = UUID(uuidString: rawSurfaceID)
      else { return nil }
      self = .contextSignal(id: id, metadata: metadata, surfaceID: surfaceID)
      return
    }
    var extracted: [String: String] = [:]
    for (key, value) in dict where key != "deeplink" && key != "query" {
      if let str = value as? String { extracted[key] = str }
    }
    // Query takes precedence when both keys are present.
    if let resource = dict["query"] as? String {
      self = .query(resource: resource, params: extracted)
    } else if let deeplink = dict["deeplink"] as? String {
      self = .command(deeplink: deeplink, params: extracted)
    } else {
      return nil
    }
  }
}
