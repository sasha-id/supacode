import Foundation

/// Agent-presence wire format, carried over one of two transports.
///
/// The metadata is identical on both, so `parse` / `parseNotify` are the single
/// ingest for either:
/// - **Unix socket** (local): a one-line JSON object
///   `{"signal":"<agent>","metadata":"<metadata>","surface_id":"<uuid>"}` piped to
///   a socket the app is listening on. The transport whenever one is named in
///   the environment, because it never touches the agent's terminal. A socket
///   that is named but unreachable drops the signal rather than falling back:
///   see `sendShell`.
/// - **OSC 3008** (UAPI hierarchical context signal): `OSC 3008 ; <action>=<agent>
///   ; <metadata> ST` written to the agent's tty. libghostty splits that into
///   `id = <agent>` (the context id, up to the first `;`) and the metadata that
///   `parse` receives. Inert in any terminal that doesn't handle OSC 3008 (no
///   toast, no side effect). The transport only for a surface that names no
///   socket at all — plain SSH with no reverse forward.
///
/// The tty is a shared resource: the agent is writing its own frames to it, and a
/// hook's bytes land between the chunks the kernel splits a large write into,
/// i.e. mid-escape-sequence. That corrupts the agent's rendering, and no amount
/// of shrinking the payload closes the window — only not writing does. Hence a
/// surface that names a socket never writes to the tty, not even when the socket
/// turns out to be unreachable (#390 made OSC unconditional and shipped that
/// corruption to every local session; a socket-failure fallback re-opened the
/// same window whenever the app's listener went away under a live session).
///
/// Presence metadata is `event=<event>[;pid=<pid>]`, and `parse` derives the event
/// solely from the `event=` field, ignoring the start/end action byte:
/// - attribution is by the receiving surface for OSC, by `surface_id` for the
///   socket, so presence metadata carries no surface id;
/// - `event` is the `HookEvent` rawValue;
/// - `pid` is the agent's process id, emitted whenever the socket transport is
///   available; it feeds the app's liveness sweep so a crashed agent is reaped.
///   The sweep is local, so a remote surface's pid is meaningless there and the
///   app drops it on ingest (`AgentSignal.presenceEvent(carriesLocalPID:)`) —
///   the emitter cannot tell the two apart once a remote host has a forwarded
///   socket.
///
/// Both transports also carry the rich notification leg
/// (`kind=notify;title=<base64>;body=<base64>`); the emitter extracts the display
/// title/body so the wire stays small and the app carries no agent-specific JSON
/// shape. Presence and notify are disjoint metadata shapes.
///
/// Signals are unauthenticated: anything that can write to the terminal or the
/// socket can emit one, and the worst case is a spurious badge or notification
/// (text is control-char-sanitized and length-capped app-side). Emission is gated
/// on `SUPACODE_SURFACE_ID` so it no-ops outside a Supacode surface.
///
/// Single source of truth for both the emit side (the agent hook) and the parse
/// side (the app), so the field names can't drift.
public nonisolated enum AgentPresenceOSC {
  /// Env var present only on Supacode surfaces, so its presence is the
  /// no-op-outside-Supacode emit gate.
  public static let surfaceEnvVar = "SUPACODE_SURFACE_ID"

  /// Env var carrying the path of a socket that accepts agent signals: the
  /// app's control socket on a local surface, or a reverse-forwarded
  /// signals-only socket on a remote one. Its presence is the transport
  /// discriminator. It is NOT a local-host check — see `pid` above.
  public static let socketEnvVar = "SUPACODE_SOCKET_PATH"

  /// Env var carrying a signals-only socket whose name outlives the app process
  /// that bound it. Preferred over `socketEnvVar`, which is the per-instance
  /// control socket the CLI discovers by pid: an agent that outlives an app
  /// restart still holds the old pid in its environment, so every hook would
  /// fail the socket arm and resume writing OSC into the agent's own tty. This
  /// name survives the restart, so the signal keeps reaching the app.
  public static let signalSocketEnvVar = "SUPACODE_SIGNAL_SOCKET_PATH"

  /// Shell expression resolving the socket the emitters should use, preferring
  /// the restart-stable name.
  static let socketPathExpression =
    #"${\#(signalSocketEnvVar):-${\#(socketEnvVar):-}}"#

  /// Field names of the socket envelope. `signal` carries what OSC puts in the
  /// context id, `metadata` the identical key=value string, and `surface_id` the
  /// attribution the terminal stream gets for free from the receiving surface.
  public static let signalField = "signal"
  public static let metadataField = "metadata"
  public static let surfaceIDField = "surface_id"

  /// Absolute path: the hook may run with a PATH that can't reach `nc` (Grok
  /// rewrites the environment, and a stripped PATH is a supported shape).
  public static let netcatPath = "/usr/bin/nc"

  /// Seconds `nc` waits on the socket. The app acks as soon as it holds the whole
  /// envelope and then closes, so this only bounds a wedged app; the hook's own
  /// deadline is 2s.
  public static let socketTimeoutSeconds = 1

  static let eventField = "event"
  static let pidField = "pid"
  static let kindField = "kind"
  static let titleField = "title"
  static let bodyField = "body"
  static let notifyKind = "notify"

  /// Notify body source keys, in display precedence. Used by the shell extractor
  /// (`emitNotifyShell`); the Pi extension sends its body directly.
  public static let notifyBodyKeys = ["message", "last_assistant_message", "assistant_response"]

  /// Emit-side byte caps. Keep the notify metadata under libghostty's 2048-byte
  /// OSC buffer, over which the whole sequence is discarded (not truncated).
  static let notifyBodyByteBudget = 1000
  static let notifyTitleByteBudget = 160

  /// A parsed presence signal.
  public struct Signal: Equatable, Sendable {
    /// Context id, i.e. the agent rawValue.
    public let agent: String
    /// A known HookEvent rawValue. Parse rejects unknown values; stored as
    /// String so wire concerns don't leak into the enum.
    public let eventRawValue: String
    /// The agent's LOCAL process id. The emit gates it on `SUPACODE_SOCKET_PATH`
    /// so a local hook carries it and a remote one omits it; a forged positive
    /// pid at worst pins a live-looking badge until surface close.
    public let pid: pid_t?
  }

  /// Parse the OSC 3008 context id + raw key=value metadata (as surfaced by
  /// libghostty) into a `Signal`. Returns nil for anything that isn't a
  /// well-formed presence signal with a known event.
  public static func parse(id: String, metadata: String) -> Signal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard
      let rawEvent = fields[Substring(eventField)],
      HookEvent(rawValue: String(rawEvent)) != nil
    else { return nil }
    return Signal(
      agent: id,
      eventRawValue: String(rawEvent),
      pid: parsePid(fields[Substring(pidField)]),
    )
  }

  /// Parse the optional `pid=` field. Rejects non-numeric and non-positive
  /// values: a 0 / negative pid would let `kill(_:0)` match the caller's process
  /// group and pin a permanent badge in the liveness sweep.
  private static func parsePid(_ raw: Substring?) -> pid_t? {
    guard let raw, let value = pid_t(raw), value > 0 else { return nil }
    return value
  }

  /// True when the metadata carries `kind=notify`. Cheap routing check (presence
  /// vs notify) that inspects the `kind` field, not a raw substring, so a base64
  /// `body` value that happens to contain "kind=notify" can't misroute.
  public static func isNotifyMetadata(_ metadata: String) -> Bool {
    parseFields(metadata)?[Substring(kindField)] == Substring(notifyKind)
  }

  /// Split the OSC 3008 raw metadata into its `key=value` fields. Standard base64
  /// values are framing-safe here: their alphabet (A-Za-z0-9+/=) has no `;`, and
  /// the value keeps everything after the FIRST `=` (`firstIndex(of:)`), so base64
  /// `=` padding survives intact.
  ///
  /// Duplicate `event` / `kind` keys are rejected: a repeated key would otherwise
  /// pin perceived state to the last occurrence, which a splice into the wire
  /// could exploit to flip `event=` or inject `kind=notify`. All other duplicate
  /// keys keep the historical last-write-wins behavior.
  public static func parseFields(_ metadata: String) -> [Substring: Substring]? {
    var fields: [Substring: Substring] = [:]
    for pair in metadata.split(separator: ";", omittingEmptySubsequences: true) {
      guard let equalsIndex = pair.firstIndex(of: "=") else { continue }
      let key = pair[..<equalsIndex]
      if fields[key] != nil, Self.dedupedFields.contains(key) {
        return nil
      }
      fields[key] = pair[pair.index(after: equalsIndex)...]
    }
    return fields
  }

  private static let dedupedFields: Set<Substring> = [
    Substring(eventField), Substring(kindField),
  ]

  /// A parsed notification signal with already-decoded display text.
  public struct NotifySignal: Equatable, Sendable {
    public let agent: String
    /// Both nil-on-empty; the caller falls back to the agent name for a missing
    /// title and shows a title-only toast for a missing body.
    public let title: String?
    public let body: String?
    /// Raw base64 byte count of the body field on the wire, before decode. A
    /// non-zero count alongside a nil `body` means a truncation the shed loop
    /// couldn't recover, so the caller can log the silent-failure case.
    public let wireBodyByteCount: Int
  }

  /// Parse `kind=notify;title=<base64>;body=<base64>`. Requires the notify kind;
  /// title/body are optional.
  public static func parseNotify(id: String, metadata: String) -> NotifySignal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard fields[Substring(kindField)] == Substring(notifyKind) else { return nil }
    return NotifySignal(
      agent: id,
      title: decodedNotifyField(fields[Substring(titleField)]),
      body: decodedNotifyField(fields[Substring(bodyField)]),
      wireBodyByteCount: fields[Substring(bodyField)]?.utf8.count ?? 0,
    )
  }

  private static func decodedNotifyField(_ raw: Substring?) -> String? {
    guard let raw, let text = decodeNotifyValue(String(raw)), !text.isEmpty else { return nil }
    return text
  }

  /// Reverse one base64 notify field back to display text. A field byte-capped at
  /// emit can end mid-escape or mid-UTF8, so trailing bytes are shed until the
  /// quoted value parses as a JSON string (`JSONDecoder` rejects both an invalid
  /// UTF-8 tail and a dangling escape). nil only on non-base64 input; an
  /// undecodable-but-base64 field collapses to "" (treated as absent, not a
  /// parse failure).
  static func decodeNotifyValue(_ base64: String) -> String? {
    guard var data = Data(base64Encoded: base64) else { return nil }
    let quote = Data([0x22])
    let decoder = JSONDecoder()
    // 12 = full `\uXXXX\uXXXX` surrogate-pair length; covers any mid-pair cut (worst dangling tail is 11 bytes).
    for _ in 0...min(12, data.count) {
      if let text = try? decoder.decode(String.self, from: quote + data + quote) {
        return text
      }
      if data.isEmpty { break }
      data.removeLast()
    }
    return ""
  }

  /// The OSC 3008 action for an event: session_end ends a context, everything
  /// else starts / updates one. The app keys off `event=` in the metadata, not
  /// this action, so it is descriptive rather than load-bearing.
  static func action(for event: HookEvent) -> String {
    event == .sessionEnd ? "end" : "start"
  }

  /// The `key=value` metadata a PRESENCE signal carries (everything after the
  /// context id). `parse` recovers the event from this exact shape. `pidSuffix`
  /// is appended verbatim (e.g. `;pid=123`); the emit appends its own in shell,
  /// since the field is conditional. See `notifyMetadata` for the notify
  /// counterpart.
  static func metadata(event: HookEvent, pidSuffix: String = "") -> String {
    "\(eventField)=\(event.rawValue)\(pidSuffix)"
  }

  /// Shell prelude every emitting hook runs once: resolves `$__ppid` (the hook's
  /// parent agent) and clears `$__tty`, the lazily-resolved OSC sink.
  ///
  /// Neither `ps -o ppid= -p $$` (Grok collapses `$$` to a bare `$` when it rewrites
  /// the command) nor a bare `$PPID` (Grok preflights it as required env and skips
  /// the hook, #704) works; only the `:-` form survives to the runtime shell.
  /// A ppid of 0 or 1 is dropped: `kill(1, 0)`'s `EPERM` reads as alive to the
  /// liveness sweep and would pin the badge until surface close.
  static let preludeSnippet =
    #"__ppid=${PPID:-}; case "$__ppid" in 0|1) __ppid="";; esac; "#
    + #"__sock="\#(socketPathExpression)"; __tty="""#

  /// Resolves the parent agent's terminal, since hooks run with no controlling
  /// terminal of their own and `ps` reports a bare tty name (`??` falls back to
  /// `/dev/tty`). `set -f` is load-bearing: that `??` is a glob.
  ///
  /// Idempotent and lazy — it runs only inside the OSC arm, so a hook on a
  /// socket-bearing surface never pays the `ps` fork, and a composite that takes
  /// that arm twice resolves once. The resolve always lands on a non-empty path,
  /// so `$__tty` doubles as the already-resolved flag.
  static let ttyResolveSnippet =
    #"[ -n "$__tty" ] || { "#
    + #"set -f; set -- $(ps -o tty= -p "$__ppid" 2>/dev/null); __tty=${1:-}; set +f; "#
    + #"case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac; }"#

  /// Ships the signal already built into `$__md`: over the socket when the
  /// surface has one, else as OSC 3008 on the parent agent's tty.
  ///
  /// Which arm runs is decided by whether a socket is *configured*, never by
  /// whether the write to it succeeded. A configured-but-unreachable socket is
  /// always a managed surface, and the tty it would fall back to is the one the
  /// agent is actively rendering into — an OSC landing mid-frame corrupts the
  /// TUI, which is a far worse outcome than a missing presence badge. So the
  /// unreachable case emits nothing at all, and no future socket-lifecycle bug
  /// can reach a terminal. Only an unset path — plain SSH with no reverse
  /// forward, where the OSC is the sole transport — takes the tty arm.
  ///
  /// Everything on the wire is JSON-safe by construction: the metadata is
  /// `key=value` pairs whose values are event names, digits, or standard base64.
  private static func sendShell(agent: SkillAgent, action: String) -> String {
    let envelope =
      #"{"\#(signalField)":"\#(agent.rawValue)","\#(metadataField)":"%s","\#(surfaceIDField)":"%s"}"#
    let osc = #"\033]3008;\#(action)=\#(agent.rawValue);%s\033\\"#
    return #"if [ -n "$__sock" ]; then "#
      + #"printf '\#(envelope)' "$__md" "${\#(surfaceEnvVar):-}" "#
      + #"| \#(netcatPath) -U -w\#(socketTimeoutSeconds) "$__sock" >/dev/null 2>&1; "#
      + #"else \#(ttyResolveSnippet); printf '\#(osc)' "$__md" > "$__tty"; fi"#
  }

  /// Shell that emits the presence signal for `event` over the available
  /// transport. The caller guards emission on `SUPACODE_SURFACE_ID` and runs
  /// `preludeSnippet` first.
  ///
  /// The pid suffix is gated on the socket transport being available and on
  /// `$__ppid` having resolved, so a reparented shell leaves the field off the
  /// wire instead of sending a dangling `pid=`. A remote hook can satisfy both
  /// gates (its socket is reverse-forwarded), so the app, not the emitter, is
  /// what keeps a remote pid out of the local liveness sweep. A forged positive
  /// pid at worst pins a live-looking badge until surface close.
  static func emitShell(event: HookEvent, agent: SkillAgent) -> String {
    #"__md="\#(metadata(event: event))"; "#
      + #"[ -n "$__sock" ] && [ -n "$__ppid" ] "#
      + #"&& __md="$__md;\#(pidField)=$__ppid"; "#
      + sendShell(agent: agent, action: action(for: event))
  }

  /// The `key=value` metadata a notify signal carries; `title` / `body` are base64.
  static func notifyMetadata(title: String, body: String) -> String {
    "\(kindField)=\(notifyKind);\(titleField)=\(title);\(bodyField)=\(body)"
  }

  /// Notify signal whose `title` / `body` are base64-encoded when the command is
  /// composed, so the hook needs no runtime `base64` / `awk`. Standard base64
  /// carries no `;`, `%` or `"`, so it is framing-, `printf`- and JSON-safe.
  static func emitFixedNotifyShell(agent: SkillAgent, title: String, body: String) -> String {
    let encodedTitle = Data(title.utf8).base64EncodedString()
    let encodedBody = Data(body.utf8).base64EncodedString()
    return #"__md="\#(notifyMetadata(title: encodedTitle, body: encodedBody))"; "#
      + sendShell(agent: agent, action: "start")
  }

  /// Portable awk that extracts one JSON string value from the agent's hook JSON
  /// on stdin. `keys` is a comma-separated precedence list (first non-empty wins);
  /// the raw escaped value is copied verbatim up to the first unescaped `"` and
  /// capped to `budget` (a mid-escape cut is tolerated by `decodeNotifyValue`).
  /// Matches the first `"key":` occurrence, assuming a flat top-level payload.
  /// No `RS`/`\x` tricks and no single quote, so it is portable and shell-safe.
  /// The caller runs it under `LC_ALL=C` so `length`/`substr` are byte-based
  /// (gawk in a UTF-8 locale would otherwise count characters and overshoot 2048).
  /// Best-effort by design: a body nested inside an object (e.g. the key appears
  /// in an inner object before the top-level one) is not extracted correctly. The
  /// agents we target emit flat payloads; the structured Pi extension path is the
  /// canonical one when a nested shape is needed.
  static let notifyExtractAwk =
    #"function ws(c){return c==" "||c=="\t"||c=="\n"||c=="\r"}"#
    + #"function fv(s,key,  p,i,n,c,o,e){p="\""key"\"";i=index(s,p);if(i==0)return "";"#
    + #"i+=length(p);n=length(s);while(i<=n){if(ws(substr(s,i,1)))i++;else break}"#
    + #"if(substr(s,i,1)!=":")return "";i++;while(i<=n){if(ws(substr(s,i,1)))i++;else break}"#
    + #"if(substr(s,i,1)!="\"")return "";i++;o="";e=0;while(i<=n){c=substr(s,i,1);"#
    + #"if(e){o=o c;e=0;i++;continue}if(c=="\\"){o=o c;e=1;i++;continue}if(c=="\"")break;o=o c;i++}return o}"#
    + #"{d=d $0}END{n=split(keys,ks,",");v="";for(j=1;j<=n;j++){v=fv(d,ks[j]);if(v!="")break}"#
    + #"if(length(v)>budget+0)v=substr(v,1,budget+0);printf "%s",v}"#

  /// Captures the hook's JSON payload from stdin into `$__in`. One `read` returns at
  /// the newline terminating the single-line object every agent we target writes, so
  /// a host holding the pipe open does not wedge the hook; a payload with no trailing
  /// newline still blocks to the deadline, which no portable shell read avoids. A
  /// line not ending in `}` (pretty-printed JSON) drains the rest, since a truncated
  /// payload silently empties every extracted field.
  static let readStdinSnippet =
    #"IFS= read -r __in || true; case "$__in" in *"}") ;; *) __in=$__in$(cat) ;; esac"#

  /// Reads the hook JSON from stdin once, extracts a bounded title/body via a
  /// portable `awk` pass (no `jq`/`python`, so it works over SSH), base64s each,
  /// and emits the notify signal. Sending only the display fields keeps the wire
  /// under libghostty's 2048-byte OSC ceiling. Locked to STANDARD base64.
  /// `readsStdin: false` skips the capture when the caller already set `$__in`.
  ///
  /// Emission is gated on a non-empty extraction: a content-free notify still
  /// displays (the app falls back to the agent name for a missing title) and
  /// supersedes the agent's own OSC 9, so it is worse than sending nothing.
  static func emitNotifyShell(agent: SkillAgent, readsStdin: Bool = true) -> String {
    let bodyKeys = notifyBodyKeys.joined(separator: ",")
    return (readsStdin ? "\(readStdinSnippet); " : "")
      + #"__t=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(titleField)" "#
      + #"-v budget=\#(notifyTitleByteBudget) '\#(notifyExtractAwk)' | base64 | tr -d '\n'); "#
      + #"__b=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(bodyKeys)" "#
      + #"-v budget=\#(notifyBodyByteBudget) '\#(notifyExtractAwk)' | base64 | tr -d '\n'); "#
      + #"if [ -n "$__t$__b" ]; then __md="\#(notifyMetadata(title: "$__t", body: "$__b"))"; "#
      + #"\#(sendShell(agent: agent, action: "start")); fi"#
  }

  // MARK: - Stop-hook API-error probe.

  /// Bytes of the transcript tail the Stop-hook probe reads. Bounded so the hook
  /// stays cheap. Sized well above the largest realistic entry, since a single
  /// tool-result line can run to tens of kilobytes.
  static let transcriptTailBytes = 262_144

  /// Scans the transcript JSONL (compact, one object per line, oldest-first) and
  /// prints `1` when the last message entry for `sid` is an API error: a later
  /// `type:"user"` or non-error `type:"assistant"` line means the turn moved on.
  /// An empty `sid` never matches, so a hook payload without `session_id` degrades
  /// to idle rather than to another session's stale error. Substring matching
  /// assumes compact JSON; anything else fails to match and yields idle, never a
  /// spurious error. No single quote, so it survives single-quoting in shell.
  static let apiErrorScanAwk =
    #"{if(index($0,"\"isApiErrorMessage\":true")>0){if(sid!=""&&index($0,"\"sessionId\":\"" sid "\"")>0)c=1;next}"#
    + #"if(index($0,"\"type\":\"user\"")>0){c=0;next}"#
    + #"if(index($0,"\"type\":\"assistant\"")>0){c=0;next}}"#
    + #"END{printf "%s",(c?"1":"")}"#

  /// Sets `$__apierr=1` when the current turn ended in an API error. Leaves `$__in`
  /// set so a following `emitNotifyShell(readsStdin: false)` reuses the one stdin
  /// read. `awk` and `tail` only, so it works on a bare SSH host.
  static func stopApiErrorProbeShell() -> String {
    "\(readStdinSnippet); "
      + #"__tp=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="transcript_path" "#
      + #"-v budget=4096 '\#(notifyExtractAwk)'); "#
      + #"__sid=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="session_id" "#
      + #"-v budget=256 '\#(notifyExtractAwk)'); "#
      + #"__apierr=""; [ -n "$__tp" ] && [ -f "$__tp" ] && "#
      + #"__apierr=$(tail -c \#(transcriptTailBytes) "$__tp" 2>/dev/null "#
      + #"| LC_ALL=C awk -v sid="$__sid" '\#(apiErrorScanAwk)')"#
  }
}
