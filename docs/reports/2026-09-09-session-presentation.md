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

The original eight-worktree retained-host bound is superseded by the measured,
resource-aware policy described below. Retention still trades cold restores for
terminal/GPU memory. The cover makes eviction visible without pretending cold
construction has become free.

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

## Optimized native construction measurements

An isolated Release test host, with Swift optimization enabled and no DEBUG
condition, measured five fresh constructions per layout at an 800 × 600 point
viewport. The four-pane layout divides the same area into quarters. The test
uses disposable `/bin/cat` terminals and does not measure zmx replay or agent UI
redraws. Run the probe alone with parallel testing disabled; concurrent test
hosts produced first-split outliers that did not recur in the isolated run.

| Layout | Construction min / median / max | First frame min / median / max |
| --- | --- | --- |
| One pane | 5.15 / 8.72 / 17.10 ms | 13.97 / 16.78 / 30.50 ms |
| Four panes | 28.25 / 29.06 / 29.70 ms | 38.74 / 39.85 / 43.90 ms |

These small samples establish an initial cost range, not reliable tail-latency
percentiles. First-frame readiness is still not physical display scan-out.

A subsequent isolated comparison retained or closed five successive layouts,
then allowed 200 ms for compositor/autorelease cleanup before reading process
physical footprint. Five retained one-pane layouts added approximately 321 MiB
(64 MiB each); five retained four-pane layouts added approximately 458 MiB
(92 MiB each). Closing the renderers instead left approximately 10 MiB and 3 MiB
over each case's initial footprint. Immediate create/destroy samples temporarily
grew much larger, so they must not be treated as steady retained-renderer cost
or as proof of a leak. Longer-lived workload measurements remain necessary.

The displayed IOSurfaces totaled approximately 7.33 MiB for one pane and
7.38 MiB for four panes. This is only one displayed target per renderer, not all
swap-chain buffers, atlases, compositor copies, scrollback, or cached resources.
A retention estimate therefore needs both viewport size and per-renderer
overhead; displayed-target bytes alone substantially undercount the observed
footprint. Any resulting budget is a soft renderer-retention budget, not a hard
process-memory limit.

The profiling test is `GhosttySurfaceViewTests.profileColdConstruction`, enabled
only by `SUPACODE_PROFILE_TERMINAL=1`. Release test builds also define
`SUPACODE_TESTING` to expose an existing test-support accessor without enabling
DEBUG logging. Neither flag is required by normal production builds.

## Resource-aware retention

The reducer budgets recently selected worktrees by their selected-pane renderer
cost instead of a fixed count of eight. The estimate uses eight times displayed
IOSurface bytes plus 12 MiB per renderer, conservatively fitted to the isolated
measurements above. A hibernated renderer uses its recorded backing dimensions;
unavailable content uses a 64 MiB estimate. The budget is one thirty-second of
physical RAM, clamped to 256 MiB–1 GiB, with a separate 32-worktree view-tree cap.
Selection survives even when its estimate exceeds the entire budget. More
expensive older candidates can be skipped to retain affordable recent sessions.

Mounted trees consume the reducer's retained list, so an independent eight-tree
UI limit cannot undo that decision. Trimming hidden roots does not rewrite the
selected root. Transient loading/multi-selection still parks the existing trees.

This is a conservative selected-pane residency estimate, not exact avoidable
memory accounting: floating and nonhibernatable content can be counted despite
remaining live independently of recency. Existing visibility and eligibility
checks remain authoritative. Normal eviction still observes the five-minute
hibernation grace period; memory pressure retains the existing immediate sweep.
Neither the budget nor its estimate is a hard process-memory ceiling.

Focused verification passed 35 tests with no failures or skips, covering reducer
grace/pressure behavior, mounted-root retention, budget overflow, deduplication,
and the view-tree backstop. The required `make build-app` also passed. This is
not the final optimized Release smoke test or a long-running memory benchmark.

## Incremental hibernation reconciliation

Local structural actions now reconcile their own worktree and any other worktree
whose budget retention changes. Selection considers outgoing/incoming worktrees
and retention changes. Old tab IDs are captured before the child reducer runs,
so closing a tab or detaching a layout cancels removed work without scanning or
discarding unrelated timers and wake requests. Initial selection, hydration,
policy changes, and memory pressure retain full reconciliation. No persistent
ownership index was introduced.

The operation-count regression includes 256 worktrees: a local selection action
does not query the 255 unrelated hibernated renderers, while a global policy
action still visits them. This verifies reduced reconciliation work, not an
end-to-end switching latency percentile.

Pressure verification exposed and now covers mixed eligible/ineligible content,
duplicate wake cancellation, and multiple queued hibernations in the same layout
with or without a selected worktree. Renderer-only completions reconcile their
own terminal, preventing sibling timer re-arming during a pressure batch. Pending
wake cancellation precedes release, while ineligible-content grace timers run
alongside it rather than delaying it.

A rapid 33-worktree sequence also exposed delayed cancellation registration in
the previous asynchronous timer effect. Grace timers now register cancellation
synchronously through a publisher subscription that owns and cancels the clock
task. Delivery remains on the main actor, checks cancellation after the injected
clock sleep, and completes the subscription on every exit path.

Final focused verification passed 147 tests (151 runs including parameterized
cases), with zero failures or skips. This includes the immediate-cancellation
variant of the rapid 33-worktree sequence, ordinary expiry, policy disable,
pressure, close/detach, and layout lifecycle tests. `make build-app` passed.

The existing deferred surface-activity reassertion remains: it compensates for
AppKit focus reset during remount, and the current mount path does not yet offer
an equivalent explicit readiness callback. Removing it without that replacement
would weaken focus correctness. Reducing this work remains a separate follow-up.

## Sidebar profiling: test-host attribution

An opt-in Release test measured repeated reconciliation of synthetic rosters
with 100 and 1,000 worktrees. Median item-reconciliation times were 92.6 ms and
937.8 ms respectively; grouping and derived-cache phases were much smaller.
These numbers must **not** be treated as production sidebar or switching latency.

A five-second native sample of the repeated benchmark traced the dominant
stacks through `Shared.wrappedValue`, dependency cache lookup,
`TestContext.current`, and `_currentTest()` into repeated `dlsym` symbol searches.
The dependency library checks the current Swift Testing identity on cache-key
creation. Its `TestContext.current` returns immediately when `isTesting` is
false, so this sampled overhead is specific to the test host. Changing the
dependency context alone would not remove that process-level test detection.

Artifacts: `.build/performance-investigation/sidebar-release.sample.txt`,
`sidebar-sampling-release.log`, and `sidebar-baseline-samples.log`. The synthetic
fixture also starts with an empty persisted sidebar section. A non-test-host
measurement with representative populated buckets is required before using
these timings to justify a production optimization.

The follow-up standalone harness links the existing optimized app objects with
an alternate entry point. It does not initialize the normal app, open terminals,
or load the test runner. Settings and app storage are in memory. This preserves
the actual reconciliation implementation while removing Swift Testing identity
lookup. Twenty repeated samples per configuration gave these medians:

| Rows | Persisted buckets | Item reconciliation | Grouping | Derived caches |
| --- | --- | --- | --- | --- |
| 100 | Empty | 3.61 ms | 0.22 ms | 1.25 ms |
| 1,000 | Empty | 34.79 ms | 1.82 ms | 10.04 ms |
| 100 | Populated | 3.64 ms | 0.26 ms | 1.44 ms |
| 1,000 | Populated | 37.32 ms | 2.16 ms | 10.85 ms |

Populated fixtures place one tenth of rows in the pinned bucket and the rest in
unpinned. These remain synthetic roster timings, not end-to-end switching
measurements. The harness, linker script, and samples are retained under the
artifact directory as `SidebarProfile.swift`, `build-sidebar-profile.rb`, and
`sidebar-standalone-samples.log`.

The standalone sample then identified repeated per-row shared-sidebar reads and
repository ownership scans. Reconciliation now snapshots sidebar state once and
uses the enclosing repository's identity for pin/archive checks. Ordering helpers
still perform their existing per-repository shared reads; no persistent cache or
ownership index was added. The same twenty-sample optimized harness measured
populated-row item reconciliation at 1.03 ms for 100 rows and 10.75 ms for 1,000
rows, down from 3.64 ms and 37.32 ms respectively (about 72% and 71%). Empty-bucket
fixtures measured 0.86 ms and 9.20 ms. Grouping and derived-cache timings remained
roughly unchanged. Follow-up samples are in `sidebar-snapshot-samples.log`.
The required app build passed, and the full standard suite against this change
passed 3,531 tests with zero failures, 16 expected failures, and two opt-in skips
(`Test-supacode-tests-2026.09.09_13-40-03-+0800.xcresult`). Focused review found no
behavioral differences for the roster's unique-owner identity invariant.

## Bundled-theme verification isolation

The two bundled-theme integration tests previously loaded user configuration,
allowing a fixed user theme to override the light/dark pair they intended to
verify. Runtime construction now accepts an optional configuration-resolution
plan and retains it through reloads and config-change callbacks. Normal callers
leave it nil, preserving live policy resolution on every load. The two tests
disable user-file tiers, enable theme synchronization in in-memory settings, and
retain the original real-Ghostty color assertions. App reload is also checked.

All 19 bundled-override tests passed in Release, and `make build-app` passed.
The subsequent full Release test attempt encountered a test-host crash resolving
a TCA generic reducer conformance in `CloneRepositoryFormFeatureTests`; that run
does not establish a passing full suite. Logs are `theme-isolation-release.log`,
`theme-isolation-build-app.log`, and `full-suite-release.log` under the same
performance-investigation artifact directory.

The standard full-suite rerun passed 3,531 tests with zero failures, 16 expected
failures, and two opt-in profiling tests skipped (`Test-supacode-tests-2026.09.09_13-33-53-+0800.xcresult`).
Its preceding attempt failed native surface creation while Core Video reported
zero displays (`CVDisplayLinkCreateWithCGDisplays`, invalid display count), which
Ghostty surfaced as initialization failure. The unchanged native-frame test then
passed in isolation and in the full rerun. No assertion was weakened or skipped
to accommodate the transient display failure.

## Native retained-frame reveal

An opt-in Release workload creates disposable `/bin/cat` surfaces with bundled
configuration, waits for real IOSurface content, and performs 100 hide/reveal
cycles per configuration. Hide and reveal occur in the same main-actor turn;
the views stay mounted. Each reveal checks that layer content matches the current
backing dimensions and the presentation cover is absent synchronously. Settings
are in memory and windows never take keyboard focus.

| Panes | Translucent | Median native reveal | p95 | Maximum |
| --- | --- | --- | --- | --- |
| 1 | No | 0.0103 ms | 0.0230 ms | 0.0397 ms |
| 1 | Yes | 0.0099 ms | 0.0249 ms | 0.0360 ms |
| 4 | No | 0.0298 ms | 0.0420 ms | 0.0935 ms |
| 4 | Yes | 0.0320 ms | 0.0610 ms | 0.0971 ms |

All four parameterized runs passed. This measures native view visibility and
presentation readiness, not SwiftUI selection, busy terminal replay, compositor
scanout, or custom shaders. Samples and test output are retained as
`retained-reveal-samples.log` and `retained-reveal-release.log`.
The strengthened backing-dimension assertions also passed all four Release
cases (`retained-reveal-verified-release.log`); the required app build passed.

## Continuous output and unfocused reveal

A disposable `/usr/bin/yes performance` workload measures layer applications
over visible, hidden, and revealed two-second phases, with 200 ms settling after
each visibility transition. The initial Release run applied 120, zero, and 1,857
frames respectively. A second run reproduced the disparity at 120, zero, and
817. This is layer application activity, not monitor scanout frequency.

Tracing the native renderer explains the transition: hiding stops the display
link, but revealing restarts it only when focused. With no active display link,
the render thread draws on each output update. Thus an unfocused visible terminal
can submit far more frames after reveal than while display-paced. The profiling
regression now rejects a greater-than-threefold reveal increase while allowing
refresh-rate variation; it failed against the original policy at 817 versus a
360-frame bound (`background-output-regression-red.log`).

A native patch makes visibility, rather than focus, control display pacing.
Terminal bytes and focus state are unchanged. With the rebuilt native library,
the continuous-output regression passed at 120 visible, zero hidden, and 121
revealed frame applications (`shader-policy-corrected-release.log`).

The initial candidate bypassed shader animation policy because generic
`hasAnimations()` meant only that custom shaders existed. A real shader workload
reproduced unwanted display-rate animation under disabled and focused-only
unfocused policies (`shader-policy-regression-red.log`). The correction includes
the animation policy in derived renderer configuration and applies it at the
redraw decision, including configuration updates on the existing surface.

The corrected workload measured three focused disabled-policy frames, zero
unfocused disabled-policy frames, 120 focused-only focused frames, zero
focused-only unfocused frames, and 120–121 always-policy frames per two seconds.
The original disabled-policy assertion allowed only two frames and failed.
Timestamp instrumentation attributed the three frames to the existing 600 ms
focused cursor timer: offsets 0.444, 1.041, and 1.640 seconds
(`shader-policy-cadence.log`). That timer wakes cell rebuilding even with cursor
blinking disabled. The test now allows up to five focused timer frames while
keeping the unfocused bound at two; it still rejects the original display-rate
regression. Both adjusted Release regressions passed in
`shader-policy-verified-release.log`: output applied 120/0/120 frames and all six
shader policy/focus combinations passed.

The retained-reveal workload then ran alone with a three-second idle interval
for each configuration (`idle-split-verified-release.log`). All 400 reveal
assertions passed again. Quiet visible unfocused panes used the following
whole-test-host CPU, where 100% means one CPU core:

| Panes | Translucent | Process CPU | Process footprint |
| --- | --- | --- | --- |
| 1 | No | 0.75% | 92.8 MiB |
| 1 | Yes | 0.85% | 92.0 MiB |
| 4 | No | 1.55% | 128.2 MiB |
| 4 | Yes | 1.34% | 135.8 MiB |

These short intervals bound the observed visible-pacing cost in this isolated
workload, not system-wide energy use or a before/after CPU improvement. The
continuous-output and shader workloads were not running during idle sampling.
The four-pane lifecycle soak passed 120 creation/first-frame/teardown cycles
(480 native surfaces, at most four live) in 139.4 seconds
(`lifecycle-soak-release.log`). It used the existing cold-construction runtime
configuration, not the bundled-only shader/idle setup. Each cycle waited one
second after the previous group closed. Initial process footprint was 80.1 MiB;
after the final group closed and the 200 ms cleanup interval it was 104.1 MiB.
Mean pre-construction footprint across successive 20-cycle windows was 88.4,
88.6, 90.7, 101.5, 103.0, and 103.1 MiB. The final two windows show no continuing
mean growth, but this finite run does not establish absence of long-term leaks.
Four-pane first-frame latency was median 63.1 ms, p95 94.5 ms, and maximum
150.1 ms; native construction was median 49.2 ms and p95 72.1 ms. These sustained
measurements should not be conflated with the earlier five-sample cold baseline.

The final standard functional suite after native pacing and lint cleanup passed
3,531 tests with zero failures, 16 expected failures, and six opt-in profiling
tests skipped (`Test-supacode-tests-2026.09.09_14-27-35-+0800.xcresult`).
`make lint` and the required `make build-app` also passed
(`native-pacing-lint.log`, `native-pacing-build-app.log`). Native profiling ran separately in optimized Release;
the standard suite does not supply performance timing evidence.
