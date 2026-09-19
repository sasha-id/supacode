/// Bundled TypeScript extension that Supacode installs into
/// `~/.omp/agent/extensions/supacode/index.ts` to report agent
/// lifecycle hooks back to the Supacode macOS app.
nonisolated enum OmpExtensionContent {
  /// Directory name under `~/.omp/agent/extensions/`.
  static let extensionDirectoryName = "supacode"

  /// Marker comment used to identify Supacode-managed extensions.
  static let ownershipMarker = "/* supacode-managed-extension */"

  static let indexTs = """
    \(ownershipMarker)
    /**
     * Supacode + Oh My Pi integration extension.
     *
     * Reports agent lifecycle and notifications to Supacode over a Unix socket
     * when one is reachable, falling back to OSC 3008 on the controlling terminal
     * when it is not. The socket is strongly preferred: this extension runs inside
     * the agent's own process, so a terminal write lands in the middle of whatever
     * the agent is drawing, the parser eats the rest of the sequence, and the
     * agent's next output paints at the wrong cursor position. The OSC sequences
     * are inert in any terminal that does not handle OSC 3008.
     *
     * Required env var (injected automatically by Supacode on every surface):
     *   SUPACODE_SURFACE_ID  present only on a Supacode surface; absence is the
     *                        no-op gate. Signals are unauthenticated.
     * Optional:
     *   SUPACODE_SOCKET_PATH  a socket that accepts agent signals; picks the
     *                         transport and gates the pid so the app's liveness
     *                         sweep can reap a crashed agent.
     *
     * Hook event mapping:
     *   extension load      -> session_start  (agent presence badge)
     *   OMP agent_start     -> busy
     *   OMP agent_end       -> idle + notification with last_assistant_message
     *   OMP session_shutdown -> idle (subagents share the main process lifetime)
     */

    import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
    import { openSync, writeSync, closeSync } from "node:fs";
    import { createConnection, type Socket } from "node:net";

    interface NotifyContent {
      title?: string;
      body?: string;
    }

    const AGENT = "omp";

    let lastWarnedAt = 0;
    const WARN_INTERVAL_MS = 60_000;
    const SOCKET_TIMEOUT_MS = \(AgentPresenceOSC.socketTimeoutSeconds) * 1000;

    function isSupacodeSurface(): boolean {
      const id = process.env["SUPACODE_SURFACE_ID"];
      return !!id && id.length > 0;
    }

    /**
     * The agent's process id as a pid suffix, emitted only when a socket is
     * reachable. Over a forwarded socket that pid belongs to the remote host, so
     * the app decides whether to keep it; on the plain terminal leg there is no
     * way to tell, hence the omission here.
     */
    function localPidSuffix(): string {
      return process.env["SUPACODE_SOCKET_PATH"] ? `;pid=${process.pid}` : "";
    }

    /**
     * Writes an OSC sequence to the controlling terminal. The extension runs
     * inside the OMP TUI process, which owns the terminal, so /dev/tty resolves.
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
          // Reusable cell backing the EAGAIN backoff sleep.
          const backoffCell = new Int32Array(new SharedArrayBuffer(4));
          // Cap EAGAIN retries that make no progress and back off between them,
          // so a wedged tty degrades to the outer catch (throttled warn + inert)
          // instead of pinning a core in an unbounded spin.
          let stalledWrites = 0;
          while (offset < bytes.length) {
            try {
              const written = writeSync(fd, bytes, offset, bytes.length - offset);
              if (written <= 0) {
                throw new Error(`short write (${offset}/${bytes.length} bytes)`);
              }
              offset += written;
              stalledWrites = 0;
            } catch (writeErr) {
              const code = (writeErr as NodeJS.ErrnoException).code;
              // EINTR is a signal artifact, not a stall: retry immediately.
              if (code === "EINTR") continue;
              // EAGAIN means the tty is momentarily full: back off, and give up
              // once it never drains so the emit degrades instead of spinning.
              if (code === "EAGAIN" && stalledWrites < 100) {
                stalledWrites++;
                Atomics.wait(backoffCell, 0, 0, 5);
                continue;
              }
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
     * app has acked and half-closed, so a missing, stale, or wedged listener
     * falls through to the terminal instead of swallowing the signal.
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
     * Queues one signal, preferring the out-of-band socket. The terminal write
     * is the fallback for a surface that has none: this extension runs inside
     * the agent's own process, so an OSC lands mid-render and corrupts the TUI.
     */
    function emit(action: string, meta: string): Promise<void> {
      const surfaceID = process.env["SUPACODE_SURFACE_ID"] ?? "";
      const socketPath = process.env["SUPACODE_SOCKET_PATH"];
      emitQueue = emitQueue
        .then(async () => {
          if (socketPath) {
            const envelope = JSON.stringify({
              "\(AgentPresenceOSC.signalField)": AGENT,
              "\(AgentPresenceOSC.metadataField)": meta,
              "\(AgentPresenceOSC.surfaceIDField)": surfaceID,
            });
            if (await sendToSocket(socketPath, envelope)) return;
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

    export default function (omp: ExtensionAPI) {
      // Not running under Supacode, or not a Supacode surface: stay inert.
      if (!isSupacodeSurface()) return;

      // Extension load = agent process running. OMP has no equivalent of
      // Claude's SessionStart hook, so we fire it ourselves.
      emitPresence("session_start");

      omp.on("agent_start", (_event, _ctx) => {
        emitPresence("busy");
      });

      omp.on("agent_end", (_event, ctx) => {
        // Atomic state-set: `idle` overwrites whatever was running on the
        // Supacode side (turn-level Stop equivalent).
        emitPresence("idle");
        emitNotification({ body: lastAssistantText(ctx) });
      });

      omp.on("session_shutdown", async (_event, _ctx) => {
        // OMP loads extensions into in-process subagent sessions. Their
        // shutdown must not end the shared top-level process presence.
        // Awaited so the queue drains before OMP tears the process down, if it
        // honours the returned promise.
        await emitPresence("idle");
      });
    }
    """
}
