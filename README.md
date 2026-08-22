# Supacode

**A native macOS command center for running coding agents in parallel.**

Run several coding agents side by side from one window: each task gets its own git worktree and
its own real terminal. Sessions persist in the background, so quitting the app or dropping an SSH
connection loses nothing.

> **This is a fork** of [supabitapp/supacode](https://github.com/supabitapp/supacode) — the
> original project, by [@khoi](https://github.com/khoi) and contributors, lives upstream at
> [supacode.sh](https://supacode.sh). All credit for the app belongs to the original authors.
> This fork adds local build workarounds for newer Xcode toolchains and a performance
> refactoring of the terminal and layout hot paths.

## What's different in this fork

### Performance refactoring

The [`performance-refactoring`](https://github.com/sasha-id/supacode/tree/performance-refactoring)
branch reworks the hot paths so the app stays responsive with many worktrees and tabs open:

- Per-tab churn (terminal output, titles, activity) stays out of the root store, so a busy pane
  no longer invalidates the whole app.
- Switching worktrees is a visibility change instead of a view teardown and rebuild, and
  hibernated tabs wake off the click path under an LRU policy.
- The pane hosting chain is stable across updates and the render context is equatable, cutting
  redundant SwiftUI and AppKit work.
- Opaque backgrounds are the default, with window translucency as an explicit opt-in.
- Sidebar recomputes are gated by classifying layout changes; surface teardown and chrome upkeep
  run off the interaction path.
- Unexpected pane closes are decided by a native zmx session probe, so routine exits blank the
  pane and collapse the split in one beat instead of flashing an exit overlay.

### Newer Xcode toolchains

`main` carries local build hatches for machines where only Xcode 26.6+ is installed — see
[below](#building-on-macos-264-tahoe).

## Features

### Worktree-first workflow

Each task gets its own git worktree and terminal, so agents run in parallel without colliding.
Create one from the sidebar, a hotkey, the command palette, the CLI, or a deeplink. The sidebar
refreshes branch, file, and pull request state live, nests rows by branch, and hoists the
worktrees that need you (an agent awaiting input, a running script) to the top. Pin, archive,
auto-delete after N days, and jump to any with ⌃1 to ⌃9.

### Background session persistence

Sessions run inside [zmx](https://zmx.sh), a lightweight session daemon, not as children of the
app. Quit and relaunch, and every session reattaches exactly where you left it, scrollback
included. On by default; a quit option tears everything down when you want a clean start.

### Remote SSH repositories (Beta)

Point Supacode at a repository on a remote host over SSH and it manages that repo's worktrees
like a local one. Every git probe and the terminal share one multiplexed SSH connection, so you
authenticate (or touch your security key) once. When the host has zmx, remote sessions survive
dropped connections and laptop sleep: the connection retries and reattaches instead of
restarting. Beta, with some local-only features reduced.

### Folders and repositories

Git repositories and plain folders are both first-class in the sidebar. A folder gets a real
persistent terminal rooted there, with the same tabs, scripts, pinning, and appearance as a repo,
minus the git-only tools. You can also clone a remote URL straight into a folder.

### Coding agent presence

Supacode detects the agent in each pane and shows a live badge: busy, awaiting input, or idle. It
supports the common agents (Claude, Codex, Copilot) through hooks it installs, works locally and
over SSH, and drives notifications so you know the moment an agent needs you.

### The CLI and deeplinks

Drive the app from any terminal, script, or other tool. The `supacode` CLI manages worktrees,
tabs, splits, and repos, and every session exports its repo, worktree, tab, and surface IDs, so
commands default to the session you run them in. Deeplinks (`supacode://...`) mirror the CLI, so
you can bind an action to a hotkey or fire it from another app.

### More

- **A real terminal.** libghostty renders every session, with tabs, horizontal and vertical
  splits, per-surface backgrounds, and theme sync with the app's appearance.
- **Command palette.** Fuzzy-search and run any action without the mouse: jump to a worktree, open
  or clone a repo, manage worktrees, run scripts, and drive the full set of pull request actions.
- **Pull request tracking.** With GitHub integration on, each worktree's PR state, checks, and
  merge readiness show in the sidebar and refresh live, with configurable merge strategy.
- **Notifications and bells.** In-app and optional system notifications, a selectable sound,
  per-surface muting, and an option to float a notified worktree to the top.
- **Custom scripts.** Named commands with an icon and tint, per repository or global, that run in
  their own tab and appear in the Script Menu, the palette, and as deeplinks. Repositories also
  get setup and archive scripts.
- **Auto-updates** through Sparkle, with a selectable update channel.

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) for the pinned toolchain. Add `~/.local/bin` to your `PATH`.
- git submodules: `git submodule update --init --recursive`
- **Xcode 26.3** if you are on macOS 26.4+ (see [below](#building-on-macos-264-tahoe)).

## Quick start

```bash
git clone --recursive https://github.com/sasha-id/supacode.git
cd supacode
mise install
make doctor    # check every build prerequisite and print fixes for anything missing
make run-app   # build and launch the Debug app
```

`make doctor` verifies mise, submodules, a Zig-linkable Xcode, the Metal Toolchain, and the
pinned tools, and prints the exact command to fix anything that is missing. The build targets
run it automatically as a quiet preflight.

## Building

```bash
make build-ghostty-xcframework   # build GhosttyKit from Zig source (slow, cached)
make build-app                   # build the macOS app (Debug)
make run-app                     # build and launch
```

### Building on macOS 26.4+ (Tahoe)

GhosttyKit is built with a pinned Zig (`0.15.2`, required exactly by ghostty) whose linker
cannot link the macOS 26.4+ SDK: that SDK dropped the `arm64-macos` slice from `libSystem.tbd`
([ziglang/zig#31658](https://github.com/ziglang/zig/issues/31658)), so the build fails with a
wall of `undefined symbol` errors. Install [Xcode 26.3](https://developer.apple.com/download/all/?q=Xcode%2026.3),
which ships the macOS 26.2 SDK that still has `arm64-macos`. You do not need to switch it
globally: the build auto-detects a Zig-linkable Xcode and pins it for that build only. After
installing Xcode 26.3 once:

```bash
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch
sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

#### Without Xcode 26.3 (this fork)

If you cannot install Xcode 26.3, this fork's `main` has hatches for building with Xcode 26.6:

- `SUPACODE_ZIG_HAS_TBD_FIX=1` skips the Xcode 26.3 pin. Use it only when your Zig 0.15.2
  carries the [`libSystem.tbd` backport](https://github.com/ziglang/zig/issues/31658) that can
  link newer SDKs (Homebrew's `0.15.2_1` bottle does; the mise build does not).
- `SUPACODE_GHOSTTY_SKIP_APP=1` skips building ghostty's own app bundle, which fails to link on
  this toolchain; Supacode only consumes the xcframework.
- `scripts/local/libtool` is prepended to `PATH` automatically during the ghostty build. It
  replaces Xcode 26.6's `libtool`, which silently drops Zig-emitted objects it considers
  misaligned from merged static archives, with an `ar`-based merge.

```bash
SUPACODE_ZIG_HAS_TBD_FIX=1 SUPACODE_GHOSTTY_SKIP_APP=1 make build-app
```

See [AGENTS.md](AGENTS.md) for the full rationale and the rest of the architecture.

## Development

```bash
make check   # swift-format + swiftlint
make test    # run the tests
make format  # swift-format only
```

## Technical stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)
- [zmx](https://zmx.sh) for session persistence

## Contributing

Contributions to the app belong upstream at
[supabitapp/supacode](https://github.com/supabitapp/supacode): open an issue there first, wait
for the `ready` label, then open a focused pull request that links it. The full process,
including the rule that a human (never an AI agent) is the accountable author, is in the
[Contributing guide](CONTRIBUTING.md).

- [Contributing guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## License

See [LICENSE](LICENSE).
