/// Bundled TypeScript extension that Supacode installs into
/// `~/.pi/agent/extensions/supacode/index.ts` to report agent
/// lifecycle hooks back to the Supacode macOS app.
nonisolated enum PiExtensionContent {
  /// Directory name under `~/.pi/agent/extensions/`.
  static let extensionDirectoryName = "supacode"

  /// Marker comment used to identify Supacode-managed extensions.
  static let ownershipMarker = "/* supacode-managed-extension */"

  static let indexTs = """
    \(ownershipMarker)
    /**
     * Supacode + Pi integration extension.
     *
     * Reports agent lifecycle and notifications to Supacode over a Unix socket
     * whenever the surface has one, and as OSC 3008 on the controlling terminal
     * only when it has none. A configured socket that cannot be reached drops
     * the signal instead: this extension runs inside the agent's own process, so
     * a terminal write lands in the middle of whatever the agent is drawing, the
     * parser eats the rest of the sequence, and the agent's next output paints at
     * the wrong cursor position. The OSC sequences are inert in any terminal that
     * does not handle OSC 3008.
     *
     * Required env var (injected automatically by Supacode on every surface):
     *   SUPACODE_SURFACE_ID  present only on a Supacode surface; absence is the
     *                        no-op gate. Signals are unauthenticated.
     * Optional:
     *   SUPACODE_SIGNAL_SOCKET_PATH  a socket that accepts agent signals whose
     *                         name survives an app restart. Preferred.
     *   SUPACODE_SOCKET_PATH  the same, for a surface that predates the stable
     *                         name. Either picks the transport and gates the pid
     *                         so the app's liveness sweep can reap a crashed agent.
     *
     * Hook event mapping:
     *   extension load      -> session_start  (agent presence badge)
     *   Pi agent_start      -> busy
     *   Pi agent_end        -> idle + notification with last_assistant_message
     *   Pi session_shutdown -> session_end + idle (defensive activity reset)
     */

    import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    import { openSync, writeSync, closeSync } from "node:fs";
    import { createConnection, type Socket } from "node:net";

    interface NotifyContent {
      title?: string;
      body?: string;
    }

    const AGENT = "pi";

    let lastWarnedAt = 0;
    const WARN_INTERVAL_MS = 60_000;
    const SOCKET_TIMEOUT_MS = \(AgentPresenceOSC.socketTimeoutSeconds) * 1000;

    function isSupacodeSurface(): boolean {
      const id = process.env["SUPACODE_SURFACE_ID"];
      return !!id && id.length > 0;
    }

    /**
     * The socket to signal over. The restart-stable name wins: the per-instance
     * path an agent inherited at spawn stops existing when the app restarts, and
     * falling back to the terminal from inside the agent corrupts the TUI.
     */
    function signalSocket(): string | undefined {
      return process.env["\(AgentPresenceOSC.signalSocketEnvVar)"] || process.env["\(AgentPresenceOSC.socketEnvVar)"];
    }

    /**
     * The agent's process id as a pid suffix, emitted only when a socket is
     * reachable. Over a forwarded socket that pid belongs to the remote host, so
     * the app decides whether to keep it; on the plain terminal leg there is no
     * way to tell, hence the omission here.
     */
    function localPidSuffix(): string {
      return signalSocket() ? `;pid=${process.pid}` : "";
    }

    /**
     * Writes an OSC sequence to the controlling terminal. The extension runs
     * inside the Pi TUI process, which owns the terminal, so /dev/tty resolves.
     * Best-effort, but a systematically-failing tty is logged at most once per
     * `WARN_INTERVAL_MS` to stderr so a broken write path is distinguishable
     * from "not a Supacode surface" without spamming the log on every emit.
     */
    function writeToTerminal(sequence: string): void {
      try {
        const fd = openSync("/dev/tty", "w");
        try {
          // Loop until the full byte length lands: a short write would leave a
          // half OSC 3008 with no ST (ESC\\) and corrupt the terminal parser.
          const bytes = Buffer.from(sequence, "utf8");
          let offset = 0;
          while (offset < bytes.length) {
            try {
              const written = writeSync(fd, bytes, offset, bytes.length - offset);
              if (written <= 0) {
                throw new Error(`short write (${offset}/${bytes.length} bytes)`);
              }
              offset += written;
            } catch (writeErr) {
              // Retry interrupted / non-blocking transient errors; abort on anything else.
              const code = (writeErr as NodeJS.ErrnoException).code;
              if (code === "EINTR" || code === "EAGAIN") continue;
              throw writeErr;
            }
          }
        } finally {
          closeSync(fd);
        }
      } catch (err) {
        const now = Date.now();
        if (now - lastWarnedAt > WARN_INTERVAL_MS) {
          lastWarnedAt = now;
          const e = err as NodeJS.ErrnoException;
          const code = e.code ?? "";
          const errno = e.errno ?? "";
          const message = e.message ?? String(err);
          process.stderr.write(
            `supacode: OSC emit failed: code=${code} errno=${errno} message=${message}\\n`,
          );
        }
      }
    }

    /**
     * Sends one signal over the app's Unix socket. Resolves true only once the
     * app has acked and half-closed; a missing, stale, or wedged listener
     * resolves false, which the caller ignores: the terminal is never the
     * fallback for a surface that has a socket configured.
     */
    function sendToSocket(path: string, payload: string): Promise<boolean> {
      return new Promise((resolve) => {
        let client: Socket;
        try {
          client = createConnection({ path });
        } catch {
          resolve(false);
          return;
        }
        const settle = (ok: boolean) => {
          client.destroy();
          resolve(ok);
        };
        // Attached before anything else can fail: an unhandled "error" on a
        // socket is rethrown out of the event loop and would kill the agent.
        client.on("error", () => settle(false));
        client.setTimeout(SOCKET_TIMEOUT_MS, () => settle(false));
        client.on("close", () => resolve(false));
        client.on("connect", () => {
          // Half-close after the payload so the app sees EOF, then drain its
          // ack: leaving it unread makes the app's reply fail with EPIPE.
          client.end(payload);
          client.resume();
          client.on("end", () => settle(true));
        });
      });
    }

    /**
     * Serializes every emit. The socket leg is asynchronous while the terminal
     * leg is not, and the app cancels a debounced `idle` on any newer event, so
     * two racing emits could settle the badge on the wrong one. Chaining keeps
     * the wire order equal to the call order across both transports.
     */
    let emitQueue: Promise<void> = Promise.resolve();

    /**
     * Queues one signal. The socket is the transport whenever the surface has
     * one configured; the terminal write serves only a surface that has none.
     * A configured socket that cannot be reached drops the signal rather than
     * falling through: this extension runs inside the agent's own process, so
     * an OSC lands mid-render and corrupts the TUI, which costs more than a
     * missing badge.
     */
    function emit(action: string, meta: string): Promise<void> {
      const surfaceID = process.env["SUPACODE_SURFACE_ID"] ?? "";
      const socketPath = signalSocket();
      emitQueue = emitQueue
        .then(async () => {
          if (socketPath) {
            const envelope = JSON.stringify({
              "\(AgentPresenceOSC.signalField)": AGENT,
              "\(AgentPresenceOSC.metadataField)": meta,
              "\(AgentPresenceOSC.surfaceIDField)": surfaceID,
            });
            await sendToSocket(socketPath, envelope);
            return;
          }
          writeToTerminal(`\\x1b]3008;${action}=${AGENT};${meta}\\x1b\\\\`);
        })
        .catch(() => {});
      return emitQueue;
    }

    function emitPresence(event: string): Promise<void> {
      const action = event === "session_end" ? "end" : "start";
      return emit(action, `event=${event}${localPidSuffix()}`);
    }

    // JSON-escape (minus the surrounding quotes) so the wire matches the shell
    // awk path, byte-cap to the same budget, then base64. App-side
    // decodeNotifyValue reverses both and tolerates a mid-escape cut.
    function notifyField(value: string, budget: number): string {
      const escaped = JSON.stringify(value).slice(1, -1);
      const buf = Buffer.from(escaped, "utf8");
      const capped = buf.length > budget ? buf.subarray(0, budget) : buf;
      return capped.toString("base64");
    }

    function emitNotification(content: NotifyContent): Promise<void> {
      const meta =
        `kind=notify` +
        `;title=${notifyField(content.title ?? "", \(AgentPresenceOSC.notifyTitleByteBudget))}` +
        `;body=${notifyField(content.body ?? "", \(AgentPresenceOSC.notifyBodyByteBudget))}`;
      return emit("start", meta);
    }

    function lastAssistantText(ctx: { sessionManager: { getEntries(): any[] } }): string | undefined {
      const entries = ctx.sessionManager.getEntries();
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.type !== "message") continue;
        if (entry.message.role !== "assistant") continue;

        const content = entry.message.content;
        if (!Array.isArray(content)) continue;

        const text = content
          .filter((c: { type: string; text?: string }) => c.type === "text" && typeof c.text === "string")
          .map((c: { text: string }) => c.text)
          .join("")
          .trim();

        if (text.length > 0) return text;
      }
      return undefined;
    }

    export default function (pi: ExtensionAPI) {
      // Not running under Supacode, or not a Supacode surface: stay inert.
      if (!isSupacodeSurface()) return;

      // Extension load = agent process running. Pi has no equivalent of
      // Claude's SessionStart hook, so we fire it ourselves.
      emitPresence("session_start");

      pi.on("agent_start", (_event, _ctx) => {
        emitPresence("busy");
      });

      pi.on("agent_end", (_event, ctx) => {
        // Atomic state-set: `idle` overwrites whatever was running on the
        // Supacode side (turn-level Stop equivalent).
        emitPresence("idle");
        emitNotification({ body: lastAssistantText(ctx) });
      });

      pi.on("session_shutdown", async (_event, _ctx) => {
        // Awaited so the queue drains before Pi tears the process down, if it
        // honours the returned promise. If it does not, a lost `session_end` is
        // still reaped by the app's pid liveness sweep.
        await emitPresence("session_end");
        await emitPresence("idle");
      });
    }
    """
}
