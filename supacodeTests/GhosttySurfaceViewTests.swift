import AppKit
import Darwin
import DependenciesTestSupport
import Foundation
import GhosttyKit
import IOSurface
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct GhosttySurfaceViewTests {
  /// Measures native retained-frame reveal only, not SwiftUI selection or scan-out.
  @Test(.dependencies, .serialized, .enabled(if: TerminalPerformance.enabled), arguments: [1, 4], [false, true])
  func profileRetainedReveal(paneCount: Int, translucent: Bool) async throws {
    @Shared(.settingsFile) var settings
    $settings.withLock { $0.global.terminalTranslucencyEnabled = translucent }
    let runtime = GhosttyRuntime(
      configResolutionPlan: .init(loadUserDefaultFiles: false, loadSupacodeUserConfig: false))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: .borderless, backing: .buffered, defer: false)
    let container = NSView(frame: window.contentLayoutRect)
    window.contentView = container
    var views: [GhosttySurfaceView] = []
    defer {
      window.orderOut(nil)
      window.contentView = nil
      for view in views { view.closeSurface() }
    }
    let columns = paneCount == 1 ? 1 : 2
    let size = CGSize(width: 800 / columns, height: 600 / columns)
    let geometry = try #require(
      ContentGeometry.candidate(pointSize: size, scale: window.backingScaleFactor))
    for index in 0..<paneCount {
      let view = GhosttySurfaceView(
        id: UUID(), runtime: runtime, workingDirectory: nil,
        command: "/bin/cat", disableShellIntegration: true,
        initialGeometry: geometry, context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
      views.append(view)
      _ = try #require(view.surface, "Native profiling requires an active display.")
      let hosted = view.hostedView()
      hosted.frame = NSRect(
        x: CGFloat(index % columns) * size.width, y: CGFloat(index / columns) * size.height,
        width: size.width, height: size.height)
      container.addSubview(hosted)
    }
    window.orderFront(nil)
    container.layoutSubtreeIfNeeded()
    for view in views {
      view.preparePresentation()
      let surface = try #require(view.surface)
      await withCheckedContinuation { continuation in
        guard view.presentation.isCovered else {
          continuation.resume()
          return
        }
        let updateCover = view.presentation.onChange
        view.presentation.onChange = {
          updateCover?()
          guard !view.presentation.isCovered else { return }
          view.presentation.onChange = updateCover
          continuation.resume()
        }
        ghostty_surface_draw(surface)
      }
    }
    for iteration in 0..<100 {
      container.isHidden = true
      let started = ProcessInfo.processInfo.systemUptime
      container.isHidden = false
      for view in views { view.preparePresentation() }
      let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      for view in views {
        let frame = try #require(view.layer?.contents as? IOSurface)
        let backingSize = view.convertToBacking(view.bounds.size)
        #expect(frame.width == Int(floor(backingSize.width)))
        #expect(frame.height == Int(floor(backingSize.height)))
        #expect(!view.presentation.isCovered)
      }
      SupaLogger("TerminalPerformance").info(
        "Retained reveal: panes=\(paneCount) translucent=\(translucent) iteration=\(iteration) reveal_ms=\(elapsed)")
      await Task.yield()
    }
  }

  /// Opt-in native construction workload. Disposable windows never take
  /// keyboard focus; this measures native creation, not zmx replay completion.
  @Test(.serialized, .enabled(if: TerminalPerformance.enabled), arguments: [1, 4], [false, true])
  func profileColdConstruction(paneCount: Int, keepResident: Bool) async throws {
    let runtime = GhosttyRuntime()
    let logger = SupaLogger("TerminalPerformance")
    await Self.settleNativeCleanup()
    let initialFootprint = Self.physicalFootprint()
    var retained: [GhosttySurfaceView] = []
    defer { for view in retained { view.closeSurface() } }
    for iteration in 0..<5 {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: .borderless, backing: .buffered, defer: false)
      let container = NSView(frame: window.contentLayoutRect)
      window.contentView = container
      var views: [GhosttySurfaceView] = []
      defer {
        window.orderOut(nil)
        window.contentView = nil
        if keepResident {
          retained.append(contentsOf: views)
        } else {
          for view in views { view.closeSurface() }
        }
      }
      let columns = paneCount == 1 ? 1 : 2
      let size = CGSize(width: 800 / columns, height: 600 / columns)
      let geometry = try #require(
        ContentGeometry.candidate(pointSize: size, scale: window.backingScaleFactor))
      let footprintBefore = Self.physicalFootprint()
      let started = ProcessInfo.processInfo.systemUptime
      for index in 0..<paneCount {
        let view = GhosttySurfaceView(
          id: UUID(), runtime: runtime, workingDirectory: nil,
          command: "/bin/cat", disableShellIntegration: true,
          initialGeometry: geometry, context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
        views.append(view)
        _ = try #require(
          view.surface, "Native profiling requires an active display and a valid surface.")
        let hosted = view.hostedView()
        hosted.frame = NSRect(
          x: CGFloat(index % columns) * size.width, y: CGFloat(index / columns) * size.height,
          width: size.width, height: size.height)
        container.addSubview(hosted)
      }
      let constructionMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      window.orderFront(nil)
      container.layoutSubtreeIfNeeded()
      for view in views { view.preparePresentation() }
      for view in views {
        let surface = try #require(view.surface)
        await withCheckedContinuation { continuation in
          guard view.presentation.isCovered else {
            continuation.resume()
            return
          }
          let updateCover = view.presentation.onChange
          view.presentation.onChange = {
            updateCover?()
            guard !view.presentation.isCovered else { return }
            view.presentation.onChange = updateCover
            continuation.resume()
          }
          ghostty_surface_draw(surface)
        }
      }
      let readyMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
      var displayedTargetBytes = 0
      for view in views {
        let surface = try #require(view.layer?.contents as? IOSurface)
        displayedTargetBytes += surface.allocationSize
      }
      logger.info(
        "Cold construction: panes=\(paneCount) retained=\(keepResident) iteration=\(iteration) construction_ms=\(constructionMilliseconds) first_frame_ms=\(readyMilliseconds) displayed_target_bytes=\(displayedTargetBytes) footprint_before=\(Self.formatBytes(footprintBefore)) footprint_after=\(Self.formatBytes(Self.physicalFootprint()))"
      )
    }
    await Self.settleNativeCleanup()
    logger.info(
      "Cold retained footprint: panes=\(paneCount) retained=\(keepResident) live_renderers=\(retained.count) initial_bytes=\(Self.formatBytes(initialFootprint)) settled_bytes=\(Self.formatBytes(Self.physicalFootprint()))"
    )
  }

  private static func settleNativeCleanup() async {
    // This opt-in workload uses a fixed real-time settling interval, not a CI
    // timing assertion. Allow compositor/autorelease cleanup before sampling.
    await withCheckedContinuation { continuation in
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { continuation.resume() }
    }
  }

  private static func formatBytes(_ bytes: UInt64?) -> String {
    bytes.map(String.init) ?? "unavailable"
  }

  private static func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : nil
  }

  @Test func nativeFrameReleasesPresentationCover() async throws {
    let runtime = GhosttyRuntime()
    let geometry = try #require(ContentGeometry.candidate(pointSize: CGSize(width: 800, height: 600), scale: 2))
    let start = ContinuousClock.now
    let view = GhosttySurfaceView(
      id: UUID(), runtime: runtime, workingDirectory: nil,
      command: "/bin/cat", disableShellIntegration: true,
      initialGeometry: geometry, context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
    defer { view.closeSurface() }
    if TerminalPerformance.enabled {
      SupaLogger("TerminalPerformance").info("Test surface construction: \(start.duration(to: .now))")
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view.hostedView()
    window.contentView?.layoutSubtreeIfNeeded()
    view.preparePresentation()
    let surface = try #require(view.surface)
    await withCheckedContinuation { continuation in
      guard view.presentation.isCovered else {
        continuation.resume()
        return
      }
      let updateCover = view.presentation.onChange
      view.presentation.onChange = {
        updateCover?()
        guard !view.presentation.isCovered else { return }
        view.presentation.onChange = updateCover
        continuation.resume()
      }
      ghostty_surface_draw(surface)
    }
    #expect(view.layer?.contents != nil)
    #expect(!view.presentation.isCovered)
    window.contentView = nil
  }

  @Test func normalizedWorkingDirectoryPathRemovesTrailingSlashForNonRootPath() {
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode/")
        == "/Users/onevcat/Sync/github/supacode"
    )
    #expect(
      GhosttySurfaceView.normalizedWorkingDirectoryPath("/Users/onevcat/Sync/github/supacode///")
        == "/Users/onevcat/Sync/github/supacode"
    )
  }

  @Test func normalizedWorkingDirectoryPathKeepsRootPath() {
    #expect(GhosttySurfaceView.normalizedWorkingDirectoryPath("/") == "/")
  }

  @Test func accessibilityLineCountsLineBreaksUpToIndex() {
    let content = "alpha\nbeta\ngamma"

    #expect(GhosttySurfaceView.accessibilityLine(for: 0, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 5, in: content) == 0)
    #expect(GhosttySurfaceView.accessibilityLine(for: 6, in: content) == 1)
    #expect(GhosttySurfaceView.accessibilityLine(for: content.count, in: content) == 2)
  }

  @Test func accessibilityStringReturnsSubstringForValidRange() {
    let content = "alpha\nbeta"

    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 6, length: 4),
        in: content
      ) == "beta"
    )
    #expect(
      GhosttySurfaceView.accessibilityString(
        for: NSRange(location: 99, length: 1),
        in: content
      ) == nil
    )
  }

  @Test func shouldHealOcclusionOnlyFiresForLatchedSurfaceAtKeyWindow() {
    // Not latched (nil or visible): never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: nil, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: true, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Latched but window not key: never heal.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: false, windowIsVisible: true, requiresVisibleWindow: false
      ))
    // Typing at a key window heals even when the window server reports covered.
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: false
      ))
    // Pointer events additionally require a visible report.
    #expect(
      !GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: false, requiresVisibleWindow: true
      ))
    #expect(
      GhosttySurfaceView.shouldHealOcclusion(
        lastOcclusion: false, windowIsKey: true, windowIsVisible: true, requiresVisibleWindow: true
      ))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionSuppressesMatchingKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.1))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionIgnoresDifferentKeyUp() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 50, timestamp: 10.1))
    #expect(suppression.suppresses(keyCode: 49, timestamp: 10.2))
    #expect(!suppression.isExpired(at: 10.1))
  }

  @Test func keyboardLayoutChangeKeyUpSuppressionExpires() {
    let suppression = GhosttySurfaceView.KeyboardLayoutChangeKeyUpSuppression(
      keyCode: 49,
      timestamp: 10
    )

    #expect(!suppression.suppresses(keyCode: 49, timestamp: 11.1))
    #expect(suppression.isExpired(at: 11.1))
  }

  private static func keyEvent(
    chars: String,
    ignoringModifiers: String,
    modifiers: NSEvent.ModifierFlags
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: chars,
      charactersIgnoringModifiers: ignoringModifiers,
      isARepeat: false,
      keyCode: 4
    )!
  }

  private static func item(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: "Item", action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = mask
    return item
  }

  private static func menu(action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(action: action, keyEquivalent: keyEquivalent, mask: mask))
    return menu
  }

  /// The `⌥⌘H` chord that collides with the Hide Others built-in.
  private static func optionCommandH() -> NSEvent {
    keyEvent(chars: "˙", ignoringModifiers: "h", modifiers: [.command, .option])
  }

  private static func commandV(modifiers: NSEvent.ModifierFlags = [.command]) -> NSEvent {
    keyEvent(chars: "v", ignoringModifiers: "v", modifiers: modifiers)
  }

  /// The Hide Others built-in item bound to `⌥⌘H`.
  private static func hideOthersItem() -> NSMenuItem {
    item(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )
  }

  @Test func forwardableMenuItemSkipsHideOthersBuiltIn() {
    let menu = Self.menu(
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
      mask: [.command, .option]
    )

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) == nil)
  }

  @Test func imageOnlyCommandVRoutesForClaudeImagePaste() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotOverrideTextOrFilePaste() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.string, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.fileURL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRequiresExactCommandVAndSupportedAgent() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(modifiers: [.command, .shift]),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.opencode],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotInterruptGhosttyKeySequences() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: true,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 1
      )
    )
  }

  @Test func imageCommandVIgnoresRichTextAndUrlRepresentations() {
    // Browser / Preview image copies carry TIFF alongside RTF, HTML, or a URL; those paste as text.
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.rtf"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [NSPasteboard.PasteboardType("public.html"), .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.URL, .tiff],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVRoutesForNonTiffImageType() {
    #expect(
      GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [.png],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func imageCommandVDoesNotRouteWithoutImageType() {
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: [],
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
    #expect(
      !GhosttySurfaceView.shouldRouteCommandPasteToNativeImagePaste(
        event: Self.commandV(),
        pasteboardTypes: nil,
        imagePasteAgents: [.claude],
        keySequenceActive: false,
        keyTableDepth: 0
      )
    )
  }

  @Test func nativeImagePasteEventConvertsCommandVToControlV() throws {
    let converted = try #require(GhosttySurfaceView.nativeImagePasteEvent(from: Self.commandV()))

    #expect(converted.characters == "v")
    #expect(converted.charactersIgnoringModifiers == "v")
    #expect(converted.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control])
  }

  @Test func forwardableMenuItemKeepsAppOwnedItem() {
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) != nil)
  }

  @Test func forwardableMenuItemSkipsHideBuiltIn() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = Self.menu(action: #selector(NSApplication.hide(_:)), keyEquivalent: "h", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) == nil)
  }

  @Test func forwardableMenuItemHonorsImplicitShiftForAppOwnedItem() {
    let event = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) != nil)
  }

  @Test func forwardableMenuItemRecursesIntoSubmenusAndSkipsBuiltIns() {
    let builtInSubmenu = NSMenu()
    builtInSubmenu.addItem(Self.hideOthersItem())
    let builtInRoot = NSMenu()
    builtInRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = builtInSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: builtInRoot) == nil)

    let appSubmenu = NSMenu()
    appSubmenu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option]))
    let appRoot = NSMenu()
    appRoot.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = appSubmenu
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: appRoot) != nil)
  }

  @Test func forwardableMenuItemResolvesAppOwnedItemSharingChordWithBuiltIn() {
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command, .option])
    menu.addItem(appOwned)

    // The built-in is listed first, so this pins that we dispatch the app-owned item, never Hide Others.
    #expect(GhosttySurfaceView.forwardableMenuItem(for: Self.optionCommandH(), in: menu) === appOwned)
  }

  @Test func forwardableMenuItemIgnoresBuiltInWithNonMatchingMask() {
    let event = Self.keyEvent(chars: "h", ignoringModifiers: "h", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.hideOthersItem())
    let appOwned = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "h", mask: [.command])
    menu.addItem(appOwned)

    #expect(GhosttySurfaceView.forwardableMenuItem(for: event, in: menu) === appOwned)
  }

  @Test func menuHasSystemManagedConflictDetectsBuiltInSharingChord() {
    // A custom `close_surface` remapped onto ⌘M collides with Minimize, so the chord must
    // stay with Ghostty instead of forwarding (which could fire Minimize).
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.addItem(Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "m", mask: [.command]))
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictIgnoresAppOwnedOnlyChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let menu = Self.menu(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(!GhosttySurfaceView.menuHasSystemManagedConflict(for: event, in: menu))
  }

  @Test func menuHasSystemManagedConflictRecursesIntoSubmenus() {
    let submenu = NSMenu()
    submenu.addItem(Self.hideOthersItem())
    let root = NSMenu()
    root.addItem(withTitle: "App", action: nil, keyEquivalent: "").submenu = submenu

    #expect(GhosttySurfaceView.menuHasSystemManagedConflict(for: Self.optionCommandH(), in: root))
  }

  @Test func menuItemMatchesExactCommandChord() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "w", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsSupersetModifierChord() {
    // `⌘,` (Settings) must not match `⌘⇧,` (Ghostty's reload_config).
    let event = Self.keyEvent(chars: ",", ignoringModifiers: ",", modifiers: [.command, .shift])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: ",", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemRejectsEmptyKeyEquivalent() {
    let event = Self.keyEvent(chars: "w", ignoringModifiers: "w", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "", mask: [.command])

    #expect(!GhosttySurfaceView.menuItem(item, matches: event))
  }

  @Test func menuItemHonorsImplicitShiftBothDirections() {
    // An uppercase `keyEquivalent` encodes shift: it matches ⌘⇧A but not plain ⌘a.
    let shiftEvent = Self.keyEvent(chars: "A", ignoringModifiers: "a", modifiers: [.command, .shift])
    let plainEvent = Self.keyEvent(chars: "a", ignoringModifiers: "a", modifiers: [.command])
    let item = Self.item(action: Selector(("appOwnedAction:")), keyEquivalent: "A", mask: [.command])

    #expect(GhosttySurfaceView.menuItem(item, matches: shiftEvent))
    #expect(!GhosttySurfaceView.menuItem(item, matches: plainEvent))
  }

  private final class MenuActionTarget: NSObject {
    var fired = false
    @objc func fire(_ sender: Any?) { fired = true }
  }

  @Test func performMenuItemDispatchesEnabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Go", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = true

    #expect(GhosttySurfaceView.performMenuItem(item))
    #expect(target.fired)
  }

  @Test func performMenuItemRejectsDisabledItem() {
    let target = MenuActionTarget()
    let item = NSMenuItem(title: "Off", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.isEnabled = false

    #expect(!GhosttySurfaceView.performMenuItem(item))
    #expect(!target.fired)
  }

  @Test func performMenuItemRejectsItemWithoutAction() {
    let item = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    item.isEnabled = true

    #expect(!GhosttySurfaceView.performMenuItem(item))
  }

  @Test func dispatchForwardableChordFiresResolvedItemDirectlyOnConflict() {
    // A custom `close_surface` on ⌘M shares the chord with Minimize: dispatch must fire the resolved
    // app item directly (so its explicit-close action runs) instead of the native path, which could
    // fire Minimize.
    let target = MenuActionTarget()
    let event = Self.keyEvent(chars: "m", ignoringModifiers: "m", modifiers: [.command])
    let menu = NSMenu()
    menu.autoenablesItems = false
    let appItem = NSMenuItem(title: "Close", action: #selector(MenuActionTarget.fire(_:)), keyEquivalent: "m")
    appItem.keyEquivalentModifierMask = [.command]
    appItem.target = target
    appItem.isEnabled = true
    menu.addItem(appItem)
    menu.addItem(Self.item(action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m", mask: [.command]))

    #expect(GhosttySurfaceView.dispatchForwardableChord(appItem, for: event, in: menu))
    #expect(target.fired)
  }

  @Test func isSystemManagedMenuItemClassifiesActions() {
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: ""
    )
    #expect(GhosttySurfaceView.isSystemManagedMenuItem(hideOthers))

    let appOwned = NSMenuItem(title: "Custom", action: Selector(("appOwnedAction:")), keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(appOwned))

    let noAction = NSMenuItem(title: "Inert", action: nil, keyEquivalent: "")
    #expect(!GhosttySurfaceView.isSystemManagedMenuItem(noAction))
  }

  @Test func reportedSurfaceSizeUsesScrollContentWidth() {
    #expect(
      GhosttySurfaceScrollView.reportedSurfaceSize(
        scrollContentSize: CGSize(width: 799, height: 600),
        surfaceFrameSize: CGSize(width: 816, height: 600)
      ) == CGSize(width: 799, height: 600)
    )
  }

  @Test func wrapperSafeAreaInsetsAreZero() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    let wrapper = GhosttySurfaceScrollView(surfaceView: surfaceView)

    #expect(wrapper.safeAreaInsets.top == 0)
    #expect(wrapper.safeAreaInsets.left == 0)
    #expect(wrapper.safeAreaInsets.bottom == 0)
    #expect(wrapper.safeAreaInsets.right == 0)
  }

  @Test func hostedViewIsBuiltOnceAndReleasedOnTeardown() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )

    let hosted = surfaceView.hostedView()
    let wrappingSuperview = surfaceView.superview

    // A second host container asks for the same view, so the surface itself
    // stays where it is instead of being re-parented into a new wrapper.
    #expect(surfaceView.hostedView() === hosted)
    #expect(surfaceView.scrollWrapper === hosted)
    #expect(surfaceView.superview === wrappingSuperview)

    // Teardown drops the surface's hold on the wrapper; without it the two
    // would retain each other and the surface would never deinit.
    surfaceView.closeSurfaceDeferringFree()
    #expect(surfaceView.hostedView() !== hosted)
    surfaceView.closeSurfaceDeferringFree()
  }

  @Test func unchangedSurfaceLayoutDoesNotInvalidateItsWrapper() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    let wrapper = surfaceView.hostedView()
    wrapper.frame.size = CGSize(width: 800, height: 600)
    wrapper.layoutSubtreeIfNeeded()
    #expect(!wrapper.needsLayout)

    surfaceView.layout()

    #expect(!wrapper.needsLayout)
    #expect(surfaceView.frame.size == CGSize(width: 800, height: 600))
  }

  @Test func surfaceTrackingAreaSurvivesLayoutAndResize() {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    surfaceView.updateTrackingAreas()
    let original = surfaceView.trackingAreas.first
    #expect(original != nil)

    surfaceView.frame.size = CGSize(width: 800, height: 600)
    surfaceView.updateTrackingAreas()
    surfaceView.updateTrackingAreas()

    #expect(surfaceView.trackingAreas.count == 1)
    #expect(surfaceView.trackingAreas.first === original)
    #expect(original?.options.contains(.inVisibleRect) == true)
  }

  @Test func unchangedScrollerGeometryRetainsItsTrackingArea() throws {
    let surfaceView = GhosttySurfaceView(
      id: UUID(), runtime: GhosttyRuntime(), workingDirectory: nil,
      initialGeometry: .fallback, context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    defer { surfaceView.closeSurface() }
    let wrapper = surfaceView.hostedView()
    let scrollView = try #require(wrapper.subviews.first as? NSScrollView)
    scrollView.hasVerticalScroller = true
    wrapper.updateTrackingAreas()
    let original = try #require(wrapper.trackingAreas.first)

    wrapper.updateTrackingAreas()

    #expect(wrapper.trackingAreas.count == 1)
    #expect(wrapper.trackingAreas.first === original)

    let scroller = try #require(scrollView.verticalScroller)
    scroller.frame.size.height += 20
    wrapper.updateTrackingAreas()
    #expect(wrapper.trackingAreas.first !== original)
    #expect(wrapper.trackingAreas.first?.rect == wrapper.convert(scroller.bounds, from: scroller))

    scrollView.hasVerticalScroller = false
    wrapper.updateTrackingAreas()
    #expect(wrapper.trackingAreas.isEmpty)
  }
}
