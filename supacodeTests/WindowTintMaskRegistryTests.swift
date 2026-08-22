import AppKit
import Testing

@testable import supacode

@MainActor
struct WindowTintMaskNormalizationTests {
  @Test func shuffledRegionsNormalizeToTheSameOrder() {
    // The registry's order is unspecified, so the dedupe only holds if the same
    // set of holes always normalizes identically.
    let first = CGRect(x: 10, y: 10, width: 40, height: 40)
    let second = CGRect(x: 60, y: 10, width: 40, height: 40)
    let third = CGRect(x: 10, y: 80, width: 40, height: 40)
    #expect(
      WindowChromeApplier.normalizedHoleRects([third, first, second])
        == WindowChromeApplier.normalizedHoleRects([second, third, first])
    )
  }

  @Test func normalizationKeepsEveryHole() {
    let first = CGRect(x: 10, y: 10, width: 40, height: 40)
    let second = CGRect(x: 60, y: 10, width: 40, height: 40)
    let duplicate = CGRect(x: 10, y: 10, width: 40, height: 40)
    let normalized = WindowChromeApplier.normalizedHoleRects([first, second, duplicate])
    #expect(normalized.count == 3)
    #expect(normalized.filter { $0 == first }.count == 2)
    #expect(normalized.contains(second))
  }

  @Test func movedRegionBreaksEquality() {
    let before = [CGRect(x: 10, y: 10, width: 40, height: 40)]
    let after = [CGRect(x: 10, y: 12, width: 40, height: 40)]
    #expect(
      WindowChromeApplier.normalizedHoleRects(before)
        != WindowChromeApplier.normalizedHoleRects(after)
    )
  }

  @Test func sameOriginDifferentSizeBreaksEquality() {
    let before = [CGRect(x: 10, y: 10, width: 40, height: 40)]
    let after = [CGRect(x: 10, y: 10, width: 40, height: 20)]
    #expect(
      WindowChromeApplier.normalizedHoleRects(before)
        != WindowChromeApplier.normalizedHoleRects(after)
    )
  }
}

struct WindowTintMaskGateTests {
  // Opaque is the default now, and there the holes would reveal the same tint
  // the window backing already carries: no mask, so no region walk and no
  // alpha-blended full-window layer.
  @Test func opaqueBackgroundNeedsNoMask() {
    #expect(WindowChromeApplier.tintMaskIsNeeded(backgroundOpacity: 1) == false)
  }

  @Test func translucentBackgroundNeedsTheMask() {
    #expect(WindowChromeApplier.tintMaskIsNeeded(backgroundOpacity: 0.9))
  }
}

@MainActor
struct WindowTintMaskRegistryTests {
  private final class TestMaskRegion: NSView, WindowTintMaskRegion {}

  // The observer block escapes, so the captured result travels in a reference.
  private final class RegionBox {
    var view: NSView?
  }

  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: .borderless,
      backing: .buffered,
      defer: true
    )
  }

  @Test func attachedRegionIsRegisteredForItsOwnWindow() {
    let window = makeWindow()
    let other = makeWindow()
    let region = TestMaskRegion(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView?.addSubview(region)
    WindowTintMaskRegistry.regionDidMoveToWindow(region)
    #expect(WindowTintMaskRegistry.regions(in: window).contains { $0 === region })
    #expect(WindowTintMaskRegistry.regions(in: other).isEmpty)
    region.removeFromSuperview()
    WindowTintMaskRegistry.regionDidMoveToWindow(region)
    window.orderOut(nil)
    other.orderOut(nil)
  }

  @Test func detachedRegionIsUnregistered() {
    let window = makeWindow()
    let region = TestMaskRegion(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView?.addSubview(region)
    WindowTintMaskRegistry.regionDidMoveToWindow(region)
    region.removeFromSuperview()
    WindowTintMaskRegistry.regionDidMoveToWindow(region)
    #expect(WindowTintMaskRegistry.regions(in: window).isEmpty)
    window.orderOut(nil)
  }

  @Test func siblingRegionsAreBothRegistered() {
    let window = makeWindow()
    let first = TestMaskRegion(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let second = TestMaskRegion(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    WindowTintMaskRegistry.regionDidMoveToWindow(first)
    WindowTintMaskRegistry.regionDidMoveToWindow(second)
    let registered = WindowTintMaskRegistry.regions(in: window)
    #expect(registered.contains { $0 === first })
    #expect(registered.contains { $0 === second })
    first.removeFromSuperview()
    second.removeFromSuperview()
    WindowTintMaskRegistry.regionDidMoveToWindow(first)
    WindowTintMaskRegistry.regionDidMoveToWindow(second)
    window.orderOut(nil)
  }

  @Test func geometryChangeAnnouncesTheRegion() {
    let window = makeWindow()
    let region = TestMaskRegion(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView?.addSubview(region)
    let box = RegionBox()
    let observer = NotificationCenter.default.addObserver(
      forName: .ghosttyTintMaskRegionDidChange, object: region, queue: nil
    ) { notification in
      nonisolated(unsafe) let notification = notification
      MainActor.assumeIsolated {
        box.view = notification.object as? NSView
      }
    }
    WindowTintMaskRegistry.regionGeometryDidChange(region)
    NotificationCenter.default.removeObserver(observer)
    #expect(box.view === region)
    region.removeFromSuperview()
    window.orderOut(nil)
  }
}
