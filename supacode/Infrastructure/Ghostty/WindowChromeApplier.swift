import AppKit
import GhosttyKit
import SupacodeSettingsShared
import SwiftUI

private nonisolated let chromeLogger = SupaLogger("WindowChrome")

struct WindowAppearanceState: Equatable {
  let opacity: Double
  let isFullScreen: Bool
  let isOpaqueOverride: Bool
  let backgroundColorKey: String
}

/// A window that resolves its own tint instead of following the app-focused
/// surface (a pane window carries its pane's surface color).
@MainActor
protocol WindowTintColorProviding: NSWindow {
  var tintColor: (() -> NSColor?)? { get }
}

@MainActor
enum WindowChromeApplier {
  /// The window's tint: a self-providing window resolves its own surface,
  /// everything else follows the app-focused surface.
  static func tintColor(for window: NSWindow?, runtime: GhosttyRuntime) -> NSColor {
    if let providing = window as? WindowTintColorProviding, let color = providing.tintColor?() {
      return color
    }
    return runtime.windowTintColor()
  }

  // Each observer site owns its own `lastApplied` so they don't fight.
  static func apply(
    window: NSWindow,
    runtime: GhosttyRuntime,
    lastApplied: inout WindowAppearanceState?
  ) {
    guard window.isVisible else { return }
    let opacity = runtime.backgroundOpacity()
    let tintColor = Self.tintColor(for: window, runtime: runtime)
    let next = WindowAppearanceState(
      opacity: opacity,
      isFullScreen: window.styleMask.contains(.fullScreen),
      isOpaqueOverride: runtime.isBackgroundOpaque,
      backgroundColorKey: Self.colorKey(tintColor)
    )
    if next == lastApplied {
      return
    }
    lastApplied = next
    if !next.isFullScreen, opacity < 1, !next.isOpaqueOverride {
      window.isOpaque = false
      window.titlebarAppearsTransparent = true
      // Near-transparent backing so the window-wide blur shows through and the
      // tint is carried by `WindowTintBackdrop`, which masks the surface regions
      // out of it. A surface then composites over blur (its own opacity),
      // never over the tint (no double background).
      window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
      if let app = runtime.app {
        ghostty_set_window_background_blur(
          app,
          Unmanaged.passUnretained(window).toOpaque()
        )
      }
      return
    }
    window.isOpaque = true
    window.titlebarAppearsTransparent = !next.isFullScreen
    window.backgroundColor = tintColor
  }

  // The surface holes only earn their keep while the background is translucent:
  // at full opacity a hole reveals `window.backgroundColor`, which `apply()` has
  // already set to this same tint, so the mask is invisible while still costing
  // the region walk, a path rebuild, and an alpha-blended full-window layer.
  nonisolated static func tintMaskIsNeeded(backgroundOpacity: Double) -> Bool {
    backgroundOpacity < 1
  }

  // Even-odd mask inputs: the full `bounds` fill plus a hole per region, clipped
  // to `bounds`. A rect spanning the whole backdrop is dropped so it can't
  // even-odd-cancel the entire tint into a fully transparent window (the terminal
  // body never covers the frame view, titlebar included).
  nonisolated static func maskHoleRects(
    holeRects: [CGRect],
    bounds: CGRect
  ) -> [CGRect] {
    var rects = [bounds]
    for rect in holeRects {
      let clipped = rect.intersection(bounds)
      guard !clipped.isEmpty, clipped != bounds else { continue }
      rects.append(clipped)
    }
    return rects
  }

  // The registry hands regions back in an unspecified order, and even-odd
  // filling is order-independent, so holes are normalized to a stable order
  // before the dedupe compares them.
  nonisolated static func normalizedHoleRects(_ rects: [CGRect]) -> [CGRect] {
    rects.sorted {
      ($0.minY, $0.minX, $0.width, $0.height) < ($1.minY, $1.minX, $1.width, $1.height)
    }
  }

  // Stable per-color key for the dedupe (NSColor equality is color-space fragile).
  private static func colorKey(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "?" }
    return
      "\(Int(srgb.redComponent * 255)),\(Int(srgb.greenComponent * 255)),\(Int(srgb.blueComponent * 255))"
  }

  // The focused terminal's contrast drives the whole window's NSAppearance, so
  // the sidebar and chrome (toolbar text included) adopt light/dark to match.
  // Kept separate from `apply` and driven only by terminal-appearance changes
  // (focus / OSC 11 / config), never window key/occlusion/alert events: those
  // would re-assign the same appearance and flash the window.
  static func applyWindowAppearance(window: NSWindow, runtime: GhosttyRuntime) {
    let name: NSAppearance.Name = Self.tintColor(for: window, runtime: runtime).isLightColor ? .aqua : .darkAqua
    guard window.appearance?.name != name else { return }
    window.appearance = NSAppearance(named: name)
  }
}

// Mounted at the ContentView root so window background re-applies on
// appearance / fullscreen / config changes even when no Ghostty surface is
// currently displayed (Empty / Loading / Archived / Multi-select states).
struct WindowChromeObserver: NSViewRepresentable {
  let runtime: GhosttyRuntime

  func makeNSView(context: Context) -> WindowChromeObserverNSView {
    WindowChromeObserverNSView(runtime: runtime)
  }

  func updateNSView(_ nsView: WindowChromeObserverNSView, context: Context) {}
}

@MainActor
final class WindowChromeObserverNSView: NSView {
  private let runtime: GhosttyRuntime
  private var lastApplied: WindowAppearanceState?
  // `nonisolated(unsafe)` so `deinit` (Swift 6 nonisolated by default for
  // @MainActor classes) can release the tokens; NotificationCenter is itself
  // thread-safe, and only main-actor methods otherwise mutate the array.
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    clearObservers()
    guard let window else { return }
    addObservers(for: window)
    applyChrome()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // Reclaim the terminal-driven window.appearance: a global appearance set
    // (GhosttyColorSchemeSyncView's NSApp.appearance, or a system Light/Dark
    // flip) changes the effective appearance and would otherwise leave the
    // toolbar stuck on the wrong scheme. The guard in applyWindowAppearance
    // makes the re-set a no-op once it matches.
    applyChrome()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  // Background + appearance together, for genuine terminal-appearance changes.
  // The window-event observers call apply() alone on purpose: retinting the
  // appearance on key/occlusion events would flash the window.
  private func applyChrome() {
    apply()
    applyAppearance()
  }

  private func apply() {
    guard let window else { return }
    WindowChromeApplier.apply(window: window, runtime: runtime, lastApplied: &lastApplied)
  }

  // The window appearance is updated only here, on genuine terminal-appearance
  // changes, so it never flashes on key/occlusion/alert events.
  private func applyAppearance() {
    guard let window else { return }
    WindowChromeApplier.applyWindowAppearance(window: window, runtime: runtime)
  }

  private func addObservers(for window: NSWindow) {
    let center = NotificationCenter.default
    let windowNotifications: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didChangeOcclusionStateNotification,
      NSWindow.didChangeScreenNotification,
    ]
    for name in windowNotifications {
      observers.append(
        center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          Task { @MainActor [weak self] in self?.apply() }
        }
      )
    }
    observers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.lastApplied = nil
          self?.applyChrome()
        }
      }
    )
    // Focus move or OSC 11 on the focused surface re-tints the window and updates
    // its appearance. Posted by the manager (object: manager), so match any object.
    observers.append(
      center.addObserver(
        forName: .ghosttyFocusedSurfaceBackgroundDidChange,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.applyChrome() }
      }
    )
  }

  private func clearObservers() {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
    observers.removeAll()
  }
}

// Mounted from ContentView. Installs a single tint layer in the window's frame
// view, behind the content view, carrying the focused-surface tint so it shows
// behind the chrome (sidebar / toolbar / tab bar / empty detail). While the
// background is translucent each terminal surface's rect is masked OUT of it,
// so the holes reveal the window blur and a surface composites over blur, never
// over the tint. At full opacity — the default — the fill is opaque and no mask
// is cut.
struct WindowTintBackdrop: NSViewRepresentable {
  let runtime: GhosttyRuntime

  func makeNSView(context: Context) -> WindowTintBackdropFinder {
    WindowTintBackdropFinder(runtime: runtime)
  }

  func updateNSView(_ nsView: WindowTintBackdropFinder, context: Context) {}
}

@MainActor
final class WindowTintBackdropFinder: NSView {
  private let runtime: GhosttyRuntime
  private weak var backdrop: TintBackdropView?

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // The tint layer must live in the window's frame view (NSThemeFrame),
    // BELOW the SwiftUI hosting view: that is the only in-window level the
    // translucent chrome (sidebar / toolbar vibrancy, tab bar, detail)
    // actually reveals. A subview of `contentView` is never sampled by it.
    guard let contentView = window?.contentView,
      let frameView = contentView.superview
    else {
      // Window nil is normal teardown; a window without a reachable frame view
      // means the private hierarchy changed and the tint silently vanishes.
      if window != nil {
        chromeLogger.warning("Window frame view unavailable; tint backdrop not installed")
      }
      backdrop?.removeFromSuperview()
      backdrop = nil
      return
    }
    if backdrop?.superview !== frameView {
      backdrop?.removeFromSuperview()
      let view = TintBackdropView(runtime: runtime)
      view.translatesAutoresizingMaskIntoConstraints = true
      view.autoresizingMask = [.width, .height]
      view.frame = frameView.bounds
      frameView.addSubview(view, positioned: .below, relativeTo: contentView)
      view.refresh()
      backdrop = view
    }
  }
}

@MainActor
final class TintBackdropView: NSView {
  private let runtime: GhosttyRuntime
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
  // One rebuild per runloop turn: a worktree switch, a split resize, and
  // sustained terminal output each fire dozens of layout + region
  // notifications, and re-cutting the mask layer on every one is pure churn.
  private var maskRebuildScheduled = false

  init(runtime: GhosttyRuntime) {
    self.runtime = runtime
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = false
    addObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  deinit {
    let center = NotificationCenter.default
    for observer in observers {
      center.removeObserver(observer)
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    // Color is cheap, keep it in lockstep with bounds; the mask walk coalesces.
    refreshColor()
    setNeedsMaskRebuild()
  }

  // The no-surface fallback tint can be a dynamic color (windowBackgroundColor),
  // and `cgColor` freezes its resolution; re-resolve when the appearance flips.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshColor()
  }

  private func addObservers() {
    let center = NotificationCenter.default
    // A background change only recolors the fill, a region change re-cuts the
    // mask holes, and a config change can alter both (opacity + theme color).
    observers.append(
      center.addObserver(
        forName: .ghosttyFocusedSurfaceBackgroundDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshColor() }
      }
    )
    // Regions post from their own layout / attach / detach pass, always on main
    // (queue: nil delivers inline there), so this only marks the mask dirty;
    // the flush runs in a queued main-actor task, coalescing every post in
    // the turn into one rebuild. That task is not ordered against the frame's
    // CATransaction commit, so a vacated hole may trail its frame by one hop.
    observers.append(
      center.addObserver(
        forName: .ghosttyTintMaskRegionDidChange, object: nil, queue: nil
      ) { [weak self] notification in
        // Delivered inline on the posting main thread (queue: nil).
        nonisolated(unsafe) let notification = notification
        MainActor.assumeIsolated {
          guard let self else { return }
          // An attached region dirties only its own window's backdrop; a
          // detached one (window nil) may be leaving any window, so everyone
          // rebuilds and the vacated hole heals.
          if let region = notification.object as? NSView, let regionWindow = region.window,
            regionWindow !== self.window
          {
            return
          }
          self.setNeedsMaskRebuild()
        }
      }
    )
    // A config reload can flip translucency in either direction, so this rebuilds
    // straight away instead of marking dirty: `setNeedsMaskRebuild` is gated on
    // translucency and would not schedule the pass that drops a stale mask.
    observers.append(
      center.addObserver(
        forName: .ghosttyRuntimeConfigDidChange, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refresh() }
      }
    )
  }

  func refresh() {
    refreshColor()
    rebuildMask()
  }

  // Tint at the shared background-opacity so the chrome fill matches the
  // surfaces exactly (one homogeneous fill over the same window blur).
  private func refreshColor() {
    guard let layer else { return }
    layer.backgroundColor =
      WindowChromeApplier.tintColor(for: window, runtime: runtime)
      .withAlphaComponent(runtime.backgroundOpacity()).cgColor
  }

  private var needsTintMask: Bool {
    WindowChromeApplier.tintMaskIsNeeded(backgroundOpacity: runtime.backgroundOpacity())
  }

  private func setNeedsMaskRebuild() {
    guard needsTintMask else { return }
    guard !maskRebuildScheduled else { return }
    maskRebuildScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.maskRebuildScheduled = false
      self.rebuildMask()
    }
  }

  // While the background is translucent, each mounted surface wrapper is punched
  // as a hole so behind it there is only blur, and the surface paints its own
  // OSC 11 color over that blur at the same opacity (no double background,
  // seamless with the chrome). An opaque background needs no holes, so the whole
  // walk is skipped and any mask left from a translucent config is dropped.
  private var lastAppliedHoleRects: [CGRect]?
  private var lastAppliedMaskBounds = CGRect.null

  private func rebuildMask() {
    guard let layer else { return }
    guard needsTintMask else {
      lastAppliedHoleRects = nil
      lastAppliedMaskBounds = .null
      layer.mask = nil
      return
    }
    var holeRects: [CGRect] = []
    if let window {
      for region in WindowTintMaskRegistry.regions(in: window)
      where !region.isHiddenOrHasHiddenAncestor {
        let rect = region.convert(region.bounds, to: self)
        // `maskHoleRects` drops a hole spanning the whole backdrop (it would
        // even-odd-cancel the entire tint), so surface the doubled-tint outcome
        // rather than let it drop silently like the detached branch below.
        if rect.intersection(bounds) == bounds {
          chromeLogger.warning("Tint mask region spans the full backdrop; hole dropped, tint will double")
        }
        holeRects.append(rect)
      }
      holeRects = WindowChromeApplier.normalizedHoleRects(holeRects)
    } else {
      // No holes get punched, so the tint would double behind the terminal body.
      chromeLogger.warning("Tint backdrop has no window; mask rebuilt without region holes")
    }
    // Most layout passes move nothing relative to the backdrop; skip the
    // layer churn when the mask would be identical.
    if holeRects == lastAppliedHoleRects, bounds == lastAppliedMaskBounds {
      return
    }
    lastAppliedHoleRects = holeRects
    lastAppliedMaskBounds = bounds
    let path = CGMutablePath()
    for rect in WindowChromeApplier.maskHoleRects(holeRects: holeRects, bounds: bounds) {
      path.addRect(rect)
    }
    let mask = CAShapeLayer()
    mask.frame = bounds
    mask.path = path
    mask.fillRule = .evenOdd
    layer.mask = mask
  }
}

// A view whose bounds are cut out of the window tint (the terminal body over
// which surfaces composite). Conformers drive the tint mask through
// `WindowTintMaskRegistry` on layout and window attach/detach.
protocol WindowTintMaskRegion: NSView {}

// The live mask regions, so a rebuild reads the mounted regions directly
// instead of walking the window's view tree. Entries are weak: a region freed
// without a detach (window teardown) drops out on its own.
@MainActor
enum WindowTintMaskRegistry {
  private static let liveRegions = NSHashTable<NSView>.weakObjects()

  // Attach registers, detach unregisters, and either way the mask has to be
  // re-cut. The window a detaching region is leaving is no longer readable
  // here, so the notification carries the region and each backdrop decides for
  // itself whether the change is its own.
  static func regionDidMoveToWindow(_ region: some WindowTintMaskRegion) {
    let view: NSView = region
    if view.window == nil {
      liveRegions.remove(view)
    } else {
      liveRegions.add(view)
    }
    Self.postRegionDidChange(view)
  }

  // A registered region moved or resized within its window.
  static func regionGeometryDidChange(_ region: some WindowTintMaskRegion) {
    let view: NSView = region
    Self.postRegionDidChange(view)
  }

  static func regions(in window: NSWindow) -> [NSView] {
    liveRegions.allObjects.filter { $0.window === window }
  }

  private static func postRegionDidChange(_ region: NSView) {
    NotificationCenter.default.post(name: .ghosttyTintMaskRegionDidChange, object: region)
  }
}
