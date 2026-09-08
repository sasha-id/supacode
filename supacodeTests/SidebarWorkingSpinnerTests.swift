import AppKit
import QuartzCore
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct SidebarWorkingSpinnerTests {
  private final class ActivityWindow: NSWindow {
    var isTestOccluded = false
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { isTestOccluded ? [] : [.visible] }
  }

  private func contentsAnimation(in view: NSView) -> CAKeyframeAnimation? {
    if let layer = view.layer, let animation = contentsAnimation(in: layer) { return animation }
    return view.subviews.lazy.compactMap { contentsAnimation(in: $0) }.first
  }

  private func contentsAnimation(in layer: CALayer) -> CAKeyframeAnimation? {
    for key in layer.animationKeys() ?? [] {
      if let animation = layer.animation(forKey: key) as? CAKeyframeAnimation,
        animation.keyPath == "contents"
      {
        return animation
      }
    }
    return (layer.sublayers ?? []).lazy.compactMap { contentsAnimation(in: $0) }.first
  }

  @Test func spinnerUsesCachedFrameAnimationInsteadOfRepeatedTextUpdates() throws {
    let hosting = NSHostingView(rootView: SidebarWorkingSpinner().frame(width: 20, height: 20))
    hosting.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
    hosting.layoutSubtreeIfNeeded()

    let animation = try #require(contentsAnimation(in: hosting))
    #expect(animation.calculationMode == .discrete)
    #expect((animation.values?.count ?? 0) > 1)
    #expect(animation.repeatCount == .infinity)
  }

  @Test func unchangedAppearanceAndLayoutReuseTheRasterizedFrames() throws {
    let view = SidebarSpinnerView()
    view.configure(font: .body, isEmphasized: false, colorScheme: .dark, scale: 2)
    let first = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    for _ in 0..<20 {
      view.configure(font: .body, isEmphasized: false, colorScheme: .dark, scale: 2)
      view.frame.size = CGSize(width: 20, height: 20)
      view.layoutSubtreeIfNeeded()
    }
    let latest = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    #expect(first === latest)
    #expect(view.layer?.sublayers?.first?.speed == 0)
  }

  @Test func changedFontScaleAndSelectionRefreshCachedImages() throws {
    let view = SidebarSpinnerView()
    view.configure(font: .body, isEmphasized: false, colorScheme: .dark, scale: 1)
    let first = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    view.configure(font: .body, isEmphasized: false, colorScheme: .dark, scale: 2)
    let retina = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    #expect(retina.width >= first.width * 2 - 1)
    view.configure(font: .title, isEmphasized: true, colorScheme: .light, scale: 2)
    let large = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    #expect(large.height > retina.height)
    #expect(contentsAnimation(in: view)?.beginTime == -0.8)
  }

  @Test func visibilityTransitionsPauseAndResumeWithoutRerasterizing() throws {
    // Drive AppKit's visibility inputs without placing a test window on screen.
    let window = ActivityWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless, backing: .buffered, defer: true)
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    let view = SidebarSpinnerView()
    parent.addSubview(view)
    window.contentView?.addSubview(parent)
    defer { parent.removeFromSuperview() }
    view.configure(font: .body, isEmphasized: false, colorScheme: .dark, scale: 2)
    let layer = try #require(view.layer?.sublayers?.first)
    let image = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    #expect(layer.speed == 1)

    parent.isHidden = true
    #expect(layer.speed == 0)
    parent.isHidden = false
    #expect(layer.speed == 1)

    window.isTestOccluded = true
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(layer.speed == 0)
    window.isTestOccluded = false
    NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
    #expect(layer.speed == 1)
    let phase = layer.convertTime(CACurrentMediaTime(), from: nil)
      .truncatingRemainder(dividingBy: 0.8)
    let expected = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8)
    let difference = abs(phase - expected)
    #expect(min(difference, 0.8 - difference) < 0.04)
    let latest = try #require((contentsAnimation(in: view)?.values as? [CGImage])?.first)
    #expect(latest === image)
    view.removeFromSuperview()
    #expect(layer.speed == 0)
  }
}
