import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct GhosttyRuntimeBundledOverridesTests {
  // The window tint + appearance source must track the resolved color scheme:
  // a dark scheme yields a dark background, a light scheme a light one. Guards
  // that the bundled themes actually differ so a missing embed hard-fails
  // instead of passing vacuously (both sides would be `windowBackgroundColor`).
  @Test(.dependencies) func backgroundColorTracksColorScheme() throws {
    @Shared(.settingsFile) var settings
    $settings.withLock { $0.global.terminalThemeSyncEnabled = true }
    let runtime = GhosttyRuntime(
      initialColorScheme: .light,
      configResolutionPlan: .init(loadUserDefaultFiles: false, loadSupacodeUserConfig: false))
    let light = runtime.backgroundColor()
    runtime.setColorScheme(.dark)
    let dark = runtime.backgroundColor()
    try #require(!light.matchesTint(dark))
    #expect(light.isLightColor)
    #expect(!dark.isLightColor)
    // Re-resolution works in both directions, not just the first transition.
    runtime.setColorScheme(.light)
    #expect(runtime.backgroundColor().isLightColor)
    runtime.reloadAppConfig()
    #expect(runtime.backgroundColor().isLightColor)
  }

  // The launch-flash fix: `init` seeds the resolved scheme so the FIRST
  // `backgroundColor()` / `windowTintColor()` read (before any further
  // `setColorScheme`) is already scheme-correct, not Ghostty's default-light
  // resolution. Asserting with no interim `setColorScheme` also documents that
  // the seed's config swap lands synchronously within `init`.
  @Test(.dependencies) func initSeedsResolvedColorSchemeBeforeFirstRead() {
    @Shared(.settingsFile) var settings
    $settings.withLock { $0.global.terminalThemeSyncEnabled = true }
    let plan = GhosttyRuntime.ConfigResolution.Plan(
      loadUserDefaultFiles: false, loadSupacodeUserConfig: false)
    let dark = GhosttyRuntime(initialColorScheme: .dark, configResolutionPlan: plan)
    #expect(!dark.backgroundColor().isLightColor)
    #expect(!dark.windowTintColor().isLightColor)
    // With no focused-surface provider installed (the launch state),
    // `windowTintColor()` falls through to exactly `backgroundColor()`.
    #expect(dark.windowTintColor().matchesTint(dark.backgroundColor()))
    let light = GhosttyRuntime(initialColorScheme: .light, configResolutionPlan: plan)
    #expect(light.backgroundColor().isLightColor)
    #expect(light.windowTintColor().isLightColor)
  }

  /// Shell integration must NOT be disabled in the bundled overrides: surfaces
  /// run the real shell with zmx injected as a `command-wrapper`, so Ghostty
  /// integrates the shell exactly as without zmx. Forcing `none` here would
  /// regress OSC 7 cwd reporting (the whole point of the wrapper approach).
  @Test func bundledOverridesDoNotTouchShellIntegration() {
    #expect(!GhosttyRuntime.bundledOverridesString.contains("shell-integration"))
  }

  @Test func appOwnedOverridesKeepSurfaceCloseDetectionEnabled() {
    // The close-safety predicate is app-owned, so it lives in the final tier,
    // not the cosmetic defaults.
    #expect(GhosttyRuntime.appOwnedOverridesString.contains("confirm-close-surface = true"))
    #expect(!GhosttyRuntime.bundledOverridesString.contains("confirm-close-surface"))
  }

  @Test func appOwnedOverridesDisableGhosttyFocusFollowsMouse() {
    // Supacode's `hoverFocusMode` is the single hover-focus authority, so the
    // native Ghostty path is unbound in the final tier and cannot resurrect it.
    #expect(GhosttyRuntime.appOwnedOverridesString.contains("focus-follows-mouse = false"))
    #expect(!GhosttyRuntime.bundledOverridesString.contains("focus-follows-mouse"))
  }

  @Test func appOwnedOverridesUnbindGhosttySearchChords() {
    // Search is app-owned (the Find menu), so Ghostty's default search chords are
    // released unconditionally here, not just via customizable `AppShortcuts`, so
    // disabling or rebinding a Find shortcut can't leave Ghostty driving search.
    // Escape stays bound so it still cancels a search and reaches TUIs.
    let overrides = GhosttyRuntime.appOwnedOverridesString
    #expect(overrides.contains("keybind = super+f=unbind"))
    #expect(overrides.contains("keybind = super+e=unbind"))
    #expect(overrides.contains("keybind = super+g=unbind"))
    #expect(overrides.contains("keybind = super+shift+g=unbind"))
    #expect(overrides.contains("keybind = super+shift+f=unbind"))
  }

  @Test func configResolutionMergeLoadsBothTiers() {
    let plan = GhosttyRuntime.ConfigResolution.plan(mode: .mergeAfterDefault, supacodeUserConfigExists: true)
    #expect(plan.loadUserDefaultFiles)
    #expect(plan.loadSupacodeUserConfig)
  }

  @Test func configResolutionMergeWithoutFileLoadsOnlyDefaults() {
    let plan = GhosttyRuntime.ConfigResolution.plan(mode: .mergeAfterDefault, supacodeUserConfigExists: false)
    #expect(plan.loadUserDefaultFiles)
    #expect(!plan.loadSupacodeUserConfig)
  }

  @Test func configResolutionExclusiveSuppressesDefaultsWhenFilePresent() {
    let plan = GhosttyRuntime.ConfigResolution.plan(mode: .exclusive, supacodeUserConfigExists: true)
    #expect(!plan.loadUserDefaultFiles)
    #expect(plan.loadSupacodeUserConfig)
  }

  // Exclusive with no Supacode file must still load the standard config: booting
  // the terminal with no user config at all is worse than ignoring the mode.
  @Test func configResolutionExclusiveFallsBackWhenFileMissing() {
    let plan = GhosttyRuntime.ConfigResolution.plan(mode: .exclusive, supacodeUserConfigExists: false)
    #expect(plan.loadUserDefaultFiles)
    #expect(!plan.loadSupacodeUserConfig)
  }

  /// Each line in the heredoc is parsed as a Ghostty `key = value` directive
  /// by `ghostty_config_load_file`. Catches accidental free-form text edits.
  @Test func bundledOverridesAreKeyValueDirectives() {
    let lines = GhosttyRuntime.bundledOverridesString
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(!lines.isEmpty)
    for line in lines {
      #expect(line.contains("="), "Override line missing `=`: \(line)")
    }
  }

  // Opaque is the performance default: with both settings off, nothing forces
  // background-opacity/blur, so the terminal renders at Ghostty's own opaque
  // default and a user's own config is free to set its own opacity unopposed.
  @Test func bundledThemeLinesEmptyWhenThemeSyncAndTranslucencyAreOff() {
    let lines = GhosttyRuntime.bundledThemeLines(
      themeSyncEnabled: false,
      translucencyEnabled: false,
      lightThemePath: "/light",
      darkThemePath: "/dark"
    )
    #expect(lines.isEmpty)
  }

  @Test func bundledThemeLinesOmitThemeWhenSyncIsOff() {
    let lines = GhosttyRuntime.bundledThemeLines(
      themeSyncEnabled: false,
      translucencyEnabled: true,
      lightThemePath: "/light",
      darkThemePath: "/dark"
    )
    #expect(!lines.contains { $0.hasPrefix("theme =") })
    #expect(lines.contains("background-opacity = 0.9"))
    #expect(lines.contains("background-blur = true"))
  }

  @Test func bundledThemeLinesOmitOpacityAndBlurWhenTranslucencyIsOff() {
    let lines = GhosttyRuntime.bundledThemeLines(
      themeSyncEnabled: true,
      translucencyEnabled: false,
      lightThemePath: "/light",
      darkThemePath: "/dark"
    )
    #expect(lines.contains("theme = light:/light,dark:/dark"))
    #expect(!lines.contains { $0.hasPrefix("background-opacity") })
    #expect(!lines.contains { $0.hasPrefix("background-blur") })
  }

  @Test func bundledThemeLinesIncludeBothWhenEnabled() {
    let lines = GhosttyRuntime.bundledThemeLines(
      themeSyncEnabled: true,
      translucencyEnabled: true,
      lightThemePath: "/light",
      darkThemePath: "/dark"
    )
    #expect(lines.contains("theme = light:/light,dark:/dark"))
    #expect(lines.contains("background-opacity = 0.9"))
    #expect(lines.contains("background-blur = true"))
  }

  /// `SUPACODE_VERSION` identifies the host app (issue #440).
  @Test func terminalIdentityOverridesPublishTheAppVersion() {
    let overrides = GhosttyRuntime.terminalIdentityOverrides(version: "1.2.3")
    #expect(overrides.contains("env = SUPACODE_VERSION=1.2.3"))
  }

  /// Ghostty's seeded `TERM_PROGRAM` pair is what programs gate terminal
  /// capabilities on — Claude Code's OSC 9;4 progress reports among them — so
  /// nothing here may rename it.
  @Test func terminalIdentityOverridesLeaveTermProgramSeeded() {
    for version: String? in ["1.2.3", nil, ""] {
      let overrides = GhosttyRuntime.terminalIdentityOverrides(version: version)
      #expect(!overrides.contains("TERM_PROGRAM"))
    }
    #expect(!GhosttyRuntime.appOwnedOverridesString.contains("TERM_PROGRAM"))
    #expect(!GhosttyRuntime.bundledOverridesString.contains("TERM_PROGRAM"))
  }

  /// A missing or blank version still emits a placeholder.
  @Test func terminalIdentityOverridesFallBackWhenVersionUnavailable() {
    for version: String? in [nil, "", "   "] {
      let overrides = GhosttyRuntime.terminalIdentityOverrides(version: version)
      #expect(overrides.contains("env = SUPACODE_VERSION=unknown"))
    }
  }

  /// Surrounding whitespace is trimmed from the emitted version.
  @Test func terminalIdentityOverridesTrimVersionWhitespace() {
    let overrides = GhosttyRuntime.terminalIdentityOverrides(version: " 1.2.3 ")
    #expect(overrides.contains("env = SUPACODE_VERSION=1.2.3"))
  }

  @Test func terminalIdentityOverridesAreKeyValueDirectives() {
    let lines = GhosttyRuntime.terminalIdentityOverrides(version: "9.9.9")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    #expect(!lines.isEmpty)
    for line in lines {
      #expect(line.contains("="), "Override line missing `=`: \(line)")
    }
  }
}
