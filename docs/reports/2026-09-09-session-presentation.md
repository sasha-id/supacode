# Session switching and presentation performance

## Scope and baseline

This change follows the August performance audit and the subsequent fixes through
`b87eba80`. The earlier audit is historical, not a description of every remaining
problem: persistent worktree hosts, deferred wakes, bounded title publication,
cached activity indicators, and layout invalidation improvements already exist.
The recent compositor fixes (`32ce9215`, `16adf2f9`, `af8713cc`) were also traced
before changing their target-selection policy.

The September 9 recording shows the distinction this work targets: recent sessions
can reveal existing content immediately, while older sessions can expose an empty
or incomplete terminal during restoration. The recording alone does not identify
how much time belongs to surface construction, layout, or zmx replay.

## Implemented behavior

- Resident terminals keep the immediate path. A valid existing frame at the
  destination backing dimensions needs no spinner or transition animation.
- Dormant terminal content shows a restoring indicator before its deferred native
  construction. Where available, a downsampled, blurred preview of that same
  terminal replaces the empty background.
- A native sibling cover stays above an incomplete surface until layer contents
  have the expected backing dimensions. Observation is removed after readiness;
  ongoing terminal output does not continuously invalidate SwiftUI through it.
- New covers are suppressed during live resize. Geometry changes while already
  covered do not restart the timeout. Parking cancels delayed presentation work.
- An empty surface shows progress immediately. Other pending-frame covers delay
  their indicator by 150 ms to avoid a flash. A two-second fallback releases the
  cover and logs a warning if readiness never arrives. These timers cannot run
  while the main thread itself is blocked.
- Reduced Motion replaces animated loading with static status text. Covers use
  system colors and do not take keyboard focus.
- Preview storage is an evictable 64 MiB / 32-image cache, with at most two pending
  copies. Copies run on a utility queue and explicitly pin their source IOSurface
  until pixels are materialized. No screenshot files are written to disk.
- GPU-inflight, queued, displayed, compositor-held, and preview-pinned targets are
  excluded from rendering. There is no timeout permission to overwrite an owned
  target. Declined draws retain the completed frame and retry asynchronously.
- Selection and host activation execute together on the main actor, in that order.
  Superseded, not-yet-executed selection work is cancellable.
- Sidebar/settings encoding and writes run on an ordered utility queue. Explicit
  save errors still propagate; reads and normal termination flush accepted writes.
  Pending automatic snapshots coalesce per storage destination, without delaying
  an idle writer. Explicit saves and reads fence earlier batches. Reads remain
  synchronous to the caller.
- Tab-strip geometry uses scroll metrics instead of an inner geometry reader.
  Delayed recentering is cancelled on a new selection, another tab change, or exit.

## Deliberate limits

The eight-worktree retained-host policy remains unchanged. Increasing it without
memory-pressure measurements trades cold restores for potentially substantial
terminal/GPU memory. The cover makes that resource-saving policy visible without
pretending cold construction has become free.

Frame availability is not physical display scan-out, and is not zmx replay
completion. This change does not add a replay-completion protocol or delay terminal
output. A running application may still clear, reflow, or redraw after the first
valid frame. Those later replay jumps are intentionally outside the readiness gate.

Native surface creation and disposal remain on the main actor, consistent with
the embedded renderer's AppKit requirements. Moving those calls to an arbitrary
background task is not a safe optimization. Immutable shader-resource reuse and
incremental hibernation scans are deferred until profiling attributes enough cost
to justify their additional lifecycle complexity.

## Profiling and acceptance checks

Set `SUPACODE_PROFILE_TERMINAL=1` in the launched process environment to enable
Instruments signposts in subsystem `app.supabit.supacode`, category
`TerminalPerformance`. Intervals cover worktree-host selection, surface
construction, and first-frame availability. No terminal text or paths are attached.
Profiling is disabled by default.

A five-second sample of the previously running build was approximately 99% idle
on the main thread. It was not a controlled switching workload and cannot support
a switching speedup claim. No before/after p50 or p95 latency is claimed here.

For an interactive acceptance run, test warm A/B switching, selection beyond eight
worktrees, a cold split session, rapid A/B/C selection, hidden-window resize,
ongoing output, and Reduced Motion. Check that the destination owns its preview,
no intermediate blank terminal is exposed before readiness, and focus follows the
latest selection. Compare construction and first-frame intervals separately; use
screen recording to check visual artifacts, not just CPU duration.

Automated coverage includes readiness geometry, warm bypass, timeout behavior,
parking/new-generation cancellation, native frame handoff, selection command
ordering, off-main persistence, and explicit save failures. Native renderer tests
exercise all four-buffer ownership combinations and queued/displayed pin cleanup.

## Verification results

- Required `make build-app`: passed with the machine's existing patched-Zig SDK
  compatibility override (`SUPACODE_ZIG_HAS_TBD_FIX=1`).
- Initial focused presentation/persistence/selection run: 142 passed, no failures.
- After fixing eager dependency capture in the asynchronous writer, the focused
  settings/repository/deeplink run passed 218 tests with 10 expected failures and
  no unexpected failures. A direct default-dependency-instance regression was
  subsequently added and passed in the full run.
- Final full workspace result: 3,515 tests, comprising 3,497 passed, 16 expected
  failures, and two unexpected failures. The failures are
  `GhosttyRuntimeBundledOverridesTests.backgroundColorTracksColorScheme` and
  `initSeedsResolvedColorSchemeBeforeFirstRead`. Both also fail with synchronous
  persistence restored as a diagnostic control. Their unchanged runtime path
  loads real user configuration, so their light/dark assumptions are not isolated
  from the environment. The exact external configuration cause was not inspected.
- Native Zig verification: eight tests passed; pristine patch application and
  reverse-application checks passed.
- SwiftLint passed. Strict swift-format lint still reports three unchanged
  `forEach` style violations in `LayoutContentView` and `GhosttySurfaceView`.

The installed application was not replaced or relaunched. An interactive
before/after recording of this build remains necessary to validate perceived
smoothness and establish switching latency percentiles.

## Persistence follow-up

Automatic settings saves compare decoded domain values, so changing global
settings does not encode or rewrite unchanged routes and repositories. Explicit
saves still force all domains and surface errors. Each attempted domain is marked
unknown before writing and marked persisted only after success; a backend that
changes a file and then throws cannot suppress a later corrective write.

Hydration and persisted-value cache publication execute together on the serial
writer. Rebinding either storage closure creates a new cache and coalescing
identity. This avoids stale cache publication during reload and accidental
coalescing across different storage backends.

The focused persistence result contains 76 passing tests, zero failures and zero
skips, verified from the test-result bundle. Regressions include latest-snapshot
coalescing, explicit-save boundaries, destination separation, every caller's
failure completion, in-flight isolation, partial-write recovery, backend
rebinding, and reload/write ordering. These are functional guarantees, not a
measured switching-latency improvement.

## Content observation follow-up

Renderer availability now registers observation per content ID, including IDs
that have not been provisioned yet. Lifecycle mutations notify only that ID's
readers. Terminal views no longer observe the layout-wide render epoch; the
renderer mount is resolved in a dedicated leaf view, with renderer identity and
host-generation checks preserving ownership during hierarchy replacement.

Hidden terminal strips stop observing raw agent, progress, and working-state
changes. Their raw state continues updating for non-presentation consumers, and
the strip catches up when shown. Detached panes use their own window visibility
when deciding whether to publish presentation state.

The focused observation/layout result contains 138 passing tests, zero failures
and zero skips, verified from the test-result bundle. It includes native hosting
of first provision, replacement under the same content ID, and hibernate/rewake
without rewriting the root view or relying on a layout render epoch. Functional
coverage does not replace the remaining optimized switching workload checks.
