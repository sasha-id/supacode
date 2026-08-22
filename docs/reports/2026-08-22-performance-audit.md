# Performance Audit — Why Supacode feels slower than Ghostty

**Date:** 2026-08-22 · **Branch:** `performance-refactoring` · **Method:** static analysis of the app, `ThirdParty/ghostty`, and `ThirdParty/zmx`. Measurements proposed at the end, not yet run.

All five reported symptoms trace back to **three systemic causes**, each amplified by a handful of secondary issues. The Ghostty key/render core is a faithful port of upstream and is not the problem — the app layers wrapped around it are.

---

## The three systemic causes

### Cause 1 — The terminal hot path runs through the root TCA store, and the observing views read whole-app state

Every terminal title change (agent TUIs rewrite titles 5–10×/sec), focus change, and layout event becomes a full `AppFeature` store send. TCA observation is store-coarse, so each send invalidates:

- `WorktreeDetailView` — its body reads `store.state` wholesale (`WorktreeDetailView.swift:25`) and **contains the entire terminal subtree** (`:315`).
- `SidebarListView` — also reads `store.state` (`SidebarListView.swift:23`).

On top, every action pays `LogActionsReducer` (`Support/DebugCaseOutput.swift:14-34`, installed on the root store at `App/supacodeApp.swift:250`):

- **DEBUG:** full copy of `AppFeature.State`, deep `==`, reflective `CustomDump.diff`, and a `print()` of the diff — per action. Combined with per-title-change actions this is the single largest debug-build cost, and it scales with total app state.
- **RELEASE:** Mirror-based action label + `SentrySDK.logger.info` + a breadcrumb, per action.

This directly violates the project's own TabChrome rule ("anything a content kind produces lives on the content side, never as layout reducer state or actions").

### Cause 2 — View identity is tied to selection and topology, so switches/splits/closes destroy and rebuild the AppKit hosting chain

- `.id(selectedWorktree.id)` (`WorktreeDetailView.swift:315`) makes worktree selection a *structural* SwiftUI fact: every switch tears down the whole chain (NSViewRepresentable → nested `NSHostingView` → pane tree → scroll wrapper).
- `.id(store.layout.tree.structuralIdentity)` (`LayoutContentView.swift:90`) hashes the **entire** tree, so one split/close rebuilds every pane — new `GhosttySurfaceScrollView` (NSScrollView + document view + 6 NotificationCenter observers) per pane, full tab strip rebuild, focus reclaim Task per surface.
- The live `GhosttySurfaceView` survives but is reparented every time; the wrapper-reuse fast path (`LayoutContentView.swift:802-806`) can never hit because `makeNSView` (`:771`) always hands `mount` a fresh empty container.
- Ghostty's `IOSurfaceLayer` **discards completed frames** whose size mismatches the layer bounds mid-remount (`ThirdParty/ghostty/src/renderer/metal/IOSurfaceLayer.zig:106-116`). That discard window is the visible terminal re-render on switch.
- Un-occlusion races the view mount: the four selection effects are merged unordered (`AppFeature.swift:568-580`), so the incoming surfaces are un-occluded and kick renders before their views exist in the window; render threads also have to re-promote from `.utility` QoS via a renderer-mailbox round trip (`ThirdParty/ghostty/src/renderer/Thread.zig:264-292`).

### Cause 3 — libghostty surface lifecycle runs synchronously inside reducers on the main thread

- **Close pane:** `reduceClosePane` runs `reap` **before** `collapse` (`LayoutFeature.swift:912→916`) → `ContentRuntime.remove` → `TabContent.tearDown` (`TabContent.swift:193-201`) → `GhosttySurfaceView.closeSurface` → `ghostty_surface_free` (`GhosttySurfaceView.swift:319`). That free joins **three OS threads** (search, renderer, IO) and tears down the Metal renderer (`ThirdParty/ghostty/src/Surface.zig:777-796`) — all before SwiftUI can draw the collapsed layout, once per tab in the pane.
  - Upstream never pays this on the click: it removes the node from the tree immediately (`BaseTerminalController.swift:452-467`), the undo manager retains the old tree (`:468-511`), and `Ghostty.Surface.deinit` frees the C surface from a detached task later (`Ghostty.Surface.swift:26-35`).
- **Wake from hibernation:** `reduceWakeTab` calls `content.startSession(at:)` directly in the reducer (`LayoutFeature.swift:730`) → `ghostty_surface_new` inline on the main actor: Metal library + pipeline-state compilation, custom-shader disk IO (`renderer/generic.zig:789,836-861`, `renderer/metal/shaders.zig:118-158`), env-map build, two `std.Thread.spawn`s, PTY fork running `zmx attach`.

---

## Symptom → cause map

| Symptom | Dominant mechanism |
| --- | --- |
| Worktree switch ~1 s | Hibernation rewake: after 5 min deselected (`TerminalsFeature.swift:23`, `hibernationGraceWindow`) the surface is freed; switching back runs `ghostty_surface_new` synchronously in the reducer (Cause 3) and `zmx attach` clears the screen and replays the full serialized state over the socket. Fast switches inside the grace window pay only the remount flash (Cause 2) plus ~8–9 store sends and an O(all worktrees × panes × tabs) `reconcileHibernation` walk (`TerminalsFeature.swift:193-241`). |
| Visible terminal re-render on switch | Cause 2: reparent into a fresh scroll wrapper → IOSurface frame discards during the size-mismatch window; plus the un-occlusion/mount race and QoS re-promotion. |
| Split slower than Ghostty | Cause 2 (whole-tree identity rebuild) + Cause 1 (per-action overhead × the 3–4 actions a split emits) + the new PTY spawning at the anchor's **full** size and immediately reflowing to half (`ContentRuntime.swift:49-54`). The `ghostty_surface_new` itself is the same cost upstream pays — everything else is Supacode-added. Ghostty's own split keybind is swallowed and round-trips through `AppFeature` (`LayoutSurfaceConduit.swift:51`). |
| Close pane slower than Ghostty | Cause 3 (three thread-joins on the main thread before the tree updates) + whole-tree rebuild + per-action overhead. |
| Input lag >200 ms, key-repeat jitter | Cause 1 congestion on the main run loop (title-change actions + whole-app diffs + whole-app view invalidation contend with wakeup→tick), plus the per-keystroke/per-frame amplifiers below. Debug is dramatically worse because GhosttyKit is always `ReleaseFast` (`scripts/build-ghostty.sh:250`) — every bit of debug overhead is Swift app code compiled `-Onone` sitting exactly on these paths. |

---

## Amplifiers (per-keystroke / per-frame)

### A1 — Tint-mask rebuild walks the entire window view hierarchy, inline, per layout pass (HIGH)

`GhosttySurfaceScrollView.layout()` and `viewDidMoveToWindow()` post `.ghosttyTintMaskRegionDidChange` (`GhosttySurfaceView.swift:2221,2226`). The observer registers with `queue: nil`, so `rebuildMask()` runs synchronously inside the posting layout pass (`WindowChromeApplier.swift:357-374`), and it starts with a full recursive walk of the window's NSView tree (`:458-467`) — the `holeRects` dedupe happens **after** the walk. Scrollbar actions from the core arrive essentially per output frame and ping-pong through AppKit layout (`updateScrollbar → scroll(to:) → boundsDidChange → frame.origin → needsLayout → layout()`, `GhosttySurfaceView.swift:2211-2282`), so sustained output means a whole-window traversal per frame. Upstream has no `layout()` override on the surface view and no tint mask.

### A2 — Translucent + blurred window by default (HIGH)

The bundled theme forces `background-opacity = 0.9` + `background-blur = true` (`GhosttyRuntime.swift:753-757`) → non-opaque window + window-server blur + even-odd-masked tint backdrop (`WindowChromeApplier.swift:52-67`). Stock Ghostty is opaque. Every frame composites through blur — release builds included.

### A3 — Nested NSHostingView rootView reassigned every update; render context can never diff equal (HIGH)

`LayoutAXContainer.updateNSView` unconditionally reassigns `hostingView.rootView` (`LayoutContentView.swift:105-171`), invalidating the whole pane tree behind the AppKit boundary on every outer body pass. `PaneRenderContext` carries non-Equatable closures (`:58-68`), and `WorktreeLayoutView` mints a fresh `surfaceState` closure per body run (`WorktreeLayoutView.swift:27-43`), so SwiftUI can never short-circuit. Three SwiftUI↔AppKit boundaries sit between window and surface; upstream has one.

### A4 — Six TIS keyboard-layout syscalls per keystroke (HIGH)

`keyboardLayoutId()` eagerly evaluates three `TISCopy*` calls in an array literal (`GhosttySurfaceView.swift:1824-1839`) and is called twice per `keyDown` (`:700,703`). Upstream makes one call (`macos/Sources/Helpers/KeyboardLayout.swift`). Scales with key-repeat rate; runs before `ghostty_surface_key`.

### A5 — Modifier keys fan out to every live surface and invalidate sidebar + tab strips (MED)

Every surface installs a local event monitor including `.flagsChanged` — upstream monitors only `[.keyUp, .leftMouseDown]` — and forwards each modifier event to every non-focused surface: 2 FFI calls × N live surfaces per Shift/⌘ press *and* release (`GhosttySurfaceView.swift:276,956-960`). Supacode keeps surfaces alive across all worktrees, so N is much larger than in Ghostty. Separately, `CommandKeyObserver` writes an `@Observable` without an equality guard on every `.flagsChanged` (`CommandKeyObserver.swift:32,72`), invalidating the sidebar list and every tab strip while typing capitals.

### A6 — Sidebar recompute + agent fan-out on a 2 s cadence and per title change (MED)

`.agentSnapshotChanged` / `.terminalProjectionChanged` map to full `computeSidebarStructure` recomputes, and the work runs **before** the equality diff (`SidebarStructure.swift:414-433,318-330`). `surfaceToItemID` rebuilds a dictionary per access on the fan-out path (`AppFeature.swift:2145`). Busy sidebar rows each run a 12.5 Hz `TimelineView` spinner (`SidebarWorkingSpinner.swift:26,32`).

### A7 — Reduce Motion is dead code (MED)

`MotionPreference.reduceMotion` is a compile-time `false` (`Support/MotionPreference.swift:17`) — the system setting is never honored. `ShimmerModifier` measures geometry via `onGeometryChange` even while inactive (`ShimmerModifier.swift:11-15`).

### A8 — Debug-only: printing view bodies and a menu-rebuilding Scene body (MED)

`WorktreeDetailView.body` runs `Self._printChanges()` plus a logger `print()` per pass (`WorktreeDetailView.swift:20-26`; same in `WorktreeDetailTitleView.swift:105-108`); `SupaLogger` is an unfiltered `print()` in DEBUG. The Scene body reads high-churn state (`notificationIndicatorCount`, chrome text size, shortcut overrides) alongside the entire `.commands` block (`supacodeApp.swift:643-752`), so notification-count changes re-evaluate every `CommandGroup` → AppKit menu reconciliation — the storm class `FocusedAction` was built to prevent (#289), reintroduced one level up.

### Smaller, still real

- `contentRequestedSplit` from CLI/deeplink sends three separate store actions, each paying full per-action cost (`WorktreeTerminalManager.swift:1215-1275`).
- `handleLayoutChanged` fires for **every** layout action, not just topology changes, and runs `applySurfaceActivity` (all panes × tabs, occlusion + focus FFI per tab) **twice** — once immediately, once deferred (`WorktreeTerminalManager.swift:815-839`, `WorktreeContentHost.swift:608-651`).
- `.attachLayout` is sent unconditionally even for already-cached hosts (`WorktreeTerminalManager.swift:721`).
- `LayoutFeature`'s `isConsistent` invariant walk runs per layout action in release (`LayoutFeature.swift:249-257`, `PaneLayout.swift:388-405`).
- Synchronous main-thread JSON encodes on every `@Shared` sidebar/settings write (`SidebarPersistenceKey.swift:51-66` — whole `SidebarState`, sorted keys, 40+ call sites; `SettingsFilePersistence.swift:349-372` — three pretty-printed encodes + three file writes per mutation), some landing inside `withAnimation` transactions.
- `sidebarItems` is replaced wholesale in `syncSidebar` (~20 call sites, several under `withAnimation`), invalidating every scoped row store (`RepositoriesFeature+Sidebar.swift:114`).
- Toolbar `Menu`s keyed by `.id(scriptMenuIdentity)` including `runningScriptIDs` — every script start/stop rebuilds the AppKit menu (`WorktreeDetailView.swift:583-590,727,741`).
- `ContentView` background hosts run `CommandPaletteFeature.items(...)` and `WindowTitle.compute(...)` in body off whole-state reads (`ContentView.swift:182-226`).
- Tab strip: nested `GeometryReader`s with a per-frame `.onChange(of: contentGeo.frame(...))` writing `@State` during scroll/animation (`PaneTabStripView.swift:93-145`); `renderEpoch` read in every `PaneTabView.body` invalidates every tab on any epoch bump (`:374`).
- `bridge.state.bellCount = 0` is an unguarded `@Observable` mutation per keyDown (`GhosttySurfaceView.swift:694`).
- `healOcclusionFromUserInput` per keyDown logs + triggers a full `applySurfaceActivity` walk when a surface is mis-marked occluded (`GhosttySurfaceView.swift:689,1161-1182`).

---

## How zmx actually behaves

zmx is **not** on the fast-switch path — no process spawn, no IPC while surfaces are alive (`ZmxClient` subprocesses are `ls`/`kill` on close/quit/reap only; `ZmxSessionWatcher` tails dormant sessions on its own thread). It costs in exactly two places:

1. **Rewake replay:** on re-attach the daemon deliberately clears the screen, then serializes and streams the whole terminal state back, then resizes → SIGWINCH redraw (`ThirdParty/zmx/src/main.zig:2015,933-999`). That is the dramatic redraw after the 5-minute hibernation window.
2. **Split perceived latency:** a new pane's argv is `zmx attach <id>` — one extra process hop before the shell appears.

Other multiplexer-backed apps hide this by keeping sessions attached and toggling *visibility* (iTerm2's tmux gateway), and by replaying into a back buffer before swapping. The equivalent here: don't free surfaces on a wall-clock timer while zmx holds the real state anyway — see R3.

---

## Recommended fixes

### Quick wins (low risk, days not weeks)

| # | Change | Pays off in |
| --- | --- | --- |
| Q1 | Close pane: mutate the tree first, then free the surface from a detached task (mirror upstream's `Task.detached` free). One structural change in `ContentRuntime.remove`/`TabContent.tearDown`. | Close-pane latency — the whole symptom |
| Q2 | Delete or hard-gate `LogActionsReducer` (env-flag opt-in for DEBUG; drop or sample the per-action Sentry log + breadcrumb in release). Remove `_printChanges()`/body loggers. | Debug jitter (largest single cost), release action overhead |
| Q3 | `keyboardLayoutId()`: single lazy `TISCopyCurrentKeyboardInputSource`. | Per-keystroke cost, key-repeat |
| Q4 | Coalesce tint-mask rebuilds (dirty flag + one rebuild per runloop turn) and track wrapper frames in a registry instead of walking the window's view tree. | Sustained-output frame pacing; split/close/switch |
| Q5 | Drop `.flagsChanged` from the per-surface monitor (or forward only to visible surfaces); add an equality guard in `CommandKeyObserver`. | Typing-with-modifiers jitter |
| Q6 | Honor `accessibilityReduceMotion` (the constant is dead); make shimmer stop measuring when inactive. | Idle main-thread load |
| Q7 | Spawn split surfaces at target (half) geometry instead of full-then-reflow. | Split latency |
| Q8 | Stop sending `.attachLayout` for already-cached hosts; run `computeSidebarStructure` behind input-equality checks; fire `handleLayoutChanged`'s heavy branch only on topology changes. | Switch overhead, 2 s background churn |

### Architectural (where real Ghostty parity comes from)

**R1 — Make the terminal an island: per-terminal events never touch the root store.**
Title, pwd, progress, and focus churn belong in content-side `@Observable` objects (the existing `TabChrome` pattern — the project rule already mandates this) and reach TCA only as discrete semantic changes. Split `WorktreeDetailView` so the terminal subtree and toolbar observe narrow scoped stores instead of `store.state`. This decouples typing/agent output from sidebar, toolbar, menu, and detail-view invalidation — it addresses the input-lag symptom at its root rather than shaving per-costs.

**R2 — Make switching a visibility change, not an identity change.**
Keep one persistent AppKit host view per worktree (owned by `WorktreeTerminalManager`, which already caches hosts) and switch by hiding/showing in AppKit — remove `.id(selectedWorktree.id)`. Scope the split-tree `.id` to per-node identity so a split/close rebuilds only the affected branch. Surfaces then never reparent, the scroll wrapper survives, IOSurface frames are never discarded, and a switch becomes a compositor flip — exactly how Ghostty/iTerm tab switching stays instant. Biggest single win for switch flash, split, and close.

**R3 — Rethink hibernation: LRU + memory pressure, wake off the click path.**
The 5-minute wall-clock hibernation trades the #1 interaction (switching back) for memory zmx is holding anyway. Keep the N most-recently-used worktrees live (or hibernate only under memory pressure). When a wake is needed, run `startSession` from an effect, render the frozen snapshot (the `FrozenGrid` machinery exists) as a placeholder, and swap when the first real frame arrives. Optionally patch zmx (the `patches/` mechanism exists) to replay without the clear-screen, wrapping the replay in synchronized output (BSU/ESU) so it lands as one atomic frame.

**R4 — Flatten the hosting chain and make it diffable.**
Collapse to one SwiftUI→AppKit boundary like upstream (drop the nested `NSHostingView`, or at minimum gate `rootView` reassignment behind an Equatable snapshot). Make `PaneRenderContext` Equatable by replacing captured closures with stable references + value tokens.

**R5 — Decide on the blur deliberately.**
Offer opaque as the performance default (Ghostty parity), keep 0.9 + blur as opt-in. Measure first — it may account for a large share of the release-build "feel" difference on its own, and it's a config flip to A/B.

---

## Proposed measurements (not yet run)

1. **Blur A/B:** same build, `background-opacity = 1` vs `0.9` + blur; typing latency + Metal System Trace. Cheapest high-information test.
2. **Signposts:** `os_signpost` at keyDown→`ghostty_surface_key`, wakeup→tick, action-send→body-eval; Instruments (Hangs + SwiftUI + Time Profiler) during hold-a-key in a busy worktree, worktree switch, split, close.
3. **Debug vs release delta** on the same scenarios, isolating Q2's share before/after removing `LogActionsReducer`.
4. **Switch timeline:** signpost from `.selectionChanged` to first presented frame, with and without a hibernation wake, splitting remount-flash cost from rewake cost.

---

## Verified non-problems

Ruled out so they aren't re-chased: layout persistence (1 s debounce, encodes off-main on a serial-queue actor; `flushSync` is quit-only), zmx process spawns on the switch path (none), git/worktree polling (30–60 s, off-main), OSC-9 progress throttling (50 ms coalesced, 5 % bucketing), terminal event coalescing in `WorktreeTerminalManager` (well engineered), `TabChrome`/`ContentRuntime` design (correctly non-invalidating), `FocusedAction` coverage (one benign raw publish of a value type), `worktreeMenuSnapshot` gating (correct after #289), and wakeup→tick scheduling itself (mirrors upstream — it's the congestion around it that hurts).
