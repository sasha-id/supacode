import AppKit
import QuartzCore

/// Ghostty's surface progress bar: a 2pt overlay pinned to the top of one
/// terminal surface, carrying that surface's OSC-9 progress signal. The tab
/// stripe shows the same signal aggregated per tab; this one attributes it to a
/// pane, which is the only way to tell two splits apart while both are working.
///
/// Plain AppKit and Core Animation rather than an `NSHostingView`, mirroring
/// `TerminalPresentationCover`: every hosting view nested under a surface
/// lengthens the cursor-resolution cascade that splits already pay for.
@MainActor
final class TerminalSurfaceProgressBar: NSView {
  /// Ghostty's bar height, and the strip indicator's, so a pane reads the same
  /// weight whichever of the two is showing it.
  static let height: CGFloat = 2

  /// `BouncingProgressBar` geometry: the moving segment covers a quarter of the
  /// track and traverses the remaining three quarters, 1.2s per leg.
  private static let segmentWidthRatio: CGFloat = 0.25
  private static let bounceDuration: CFTimeInterval = 1.2
  /// Ghostty eases determinate percentage changes over 0.2s.
  private static let determinateDuration: CFTimeInterval = 0.2
  private static let bounceKey = "bounce"
  private static let determinateKey = "determinate"

  /// Only the bouncing form has a track behind it, matching Ghostty: a
  /// determinate fill paints straight onto the surface.
  private let trackLayer = CALayer()
  private let segmentLayer = CALayer()
  private var display: TerminalTabProgressDisplay?
  private var reducesMotion = true
  /// The width the running bounce was built for. `layout()` re-runs the whole
  /// geometry pass, and re-adding the animation would snap the segment back to
  /// the leading edge on every frame of a live resize.
  private var bounceWidth: CGFloat?

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // Anchored left: the determinate fill scales from the leading edge, and the
    // bouncing segment's `position.x` is its own leading edge.
    segmentLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
    trackLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
    trackLayer.opacity = 0.3
    trackLayer.isHidden = true
    layer?.addSublayer(trackLayer)
    layer?.addSublayer(segmentLayer)
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// Nil hides the bar; the bridge's stale watch is what produces that nil once
  /// a surface stops reporting, so there is no timeout of our own here.
  func update(_ display: TerminalTabProgressDisplay?, reducesMotion: Bool) {
    guard self.display != display || self.reducesMotion != reducesMotion else { return }
    // A bar that is only now appearing has nothing to ease from.
    let wasVisible = self.display != nil
    self.display = display
    self.reducesMotion = reducesMotion
    isHidden = display == nil

    guard let display else {
      stopBounce()
      segmentLayer.removeAnimation(forKey: Self.determinateKey)
      return
    }

    let color = Self.color(for: display.style).cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.backgroundColor = color
    segmentLayer.backgroundColor = color
    CATransaction.commit()

    applyGeometry(animated: wasVisible && !reducesMotion)
  }

  override func layout() {
    super.layout()
    // Geometry is width-derived, so a resize has to re-seat the segment; the
    // bounce itself only restarts when the travel distance actually changed.
    applyGeometry(animated: false)
  }

  private func applyGeometry(animated: Bool) {
    guard let display else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.bounds = CGRect(origin: .zero, size: bounds.size)
    trackLayer.position = CGPoint(x: 0, y: bounds.midY)
    CATransaction.commit()

    switch display.style {
    case .determinate(let percent):
      fill(fraction: CGFloat(max(0, min(percent, 100))) / 100, animated: animated)
    case .paused:
      // Ghostty reports a pause with no explicit percentage as 100%, so it
      // holds still rather than bouncing.
      fill(fraction: 1, animated: animated)
    case .error, .indeterminate:
      if reducesMotion {
        // The held-still form carries less information than the bounce: it is
        // the presence of the bar, not its motion, that reads as "working".
        fill(fraction: 1, animated: animated)
      } else {
        bounce()
      }
    }
  }

  /// Seat the segment across the full width and scale it from the leading edge,
  /// so a percentage change composites instead of relaying out.
  private func fill(fraction: CGFloat, animated: Bool) {
    stopBounce()
    let previous = segmentLayer.presentation()?.transform.m11 ?? segmentLayer.transform.m11

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    segmentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
    segmentLayer.position = CGPoint(x: 0, y: bounds.midY)
    segmentLayer.transform = CATransform3DMakeScale(fraction, 1, 1)
    CATransaction.commit()

    guard animated, previous != fraction else {
      segmentLayer.removeAnimation(forKey: Self.determinateKey)
      return
    }
    let animation = CABasicAnimation(keyPath: "transform.scale.x")
    animation.fromValue = previous
    animation.toValue = fraction
    animation.duration = Self.determinateDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    segmentLayer.add(animation, forKey: Self.determinateKey)
  }

  private func bounce() {
    // A zero-width surface has no travel to animate; `layout()` starts this
    // once it has real bounds.
    guard bounds.width > 0 else {
      stopBounce()
      return
    }
    guard bounceWidth != bounds.width || segmentLayer.animation(forKey: Self.bounceKey) == nil else {
      return
    }
    segmentLayer.removeAnimation(forKey: Self.determinateKey)
    bounceWidth = bounds.width
    trackLayer.isHidden = false
    let segmentWidth = bounds.width * Self.segmentWidthRatio

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    segmentLayer.bounds = CGRect(x: 0, y: 0, width: segmentWidth, height: bounds.height)
    segmentLayer.position = CGPoint(x: 0, y: bounds.midY)
    segmentLayer.transform = CATransform3DIdentity
    CATransaction.commit()

    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = 0
    animation.toValue = bounds.width - segmentWidth
    animation.duration = Self.bounceDuration
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    segmentLayer.add(animation, forKey: Self.bounceKey)
  }

  private func stopBounce() {
    bounceWidth = nil
    trackLayer.isHidden = true
    segmentLayer.removeAnimation(forKey: Self.bounceKey)
  }

  private static func color(for style: TerminalTabProgressDisplay.Style) -> NSColor {
    switch style {
    case .error: .systemRed
    case .paused: .systemOrange
    case .indeterminate, .determinate: .controlAccentColor
    }
  }
}
