import AppKit
import QuartzCore
import SupacodeSettingsShared
import SwiftUI

/// Glyphs are measured once per appearance, then advanced by the compositor.
/// Absolute phase keeps rows synchronized without a SwiftUI timer per spinner.
struct SidebarWorkingSpinner: View {
  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    SpinnerRepresentable(isEmphasized: backgroundProminence == .increased)
      .appFont(.body)
      .help("Working in this worktree")
      .accessibilityLabel("Working")
  }
}

private struct SpinnerRepresentable: NSViewRepresentable {
  let isEmphasized: Bool

  func makeNSView(context: Context) -> SidebarSpinnerView {
    SidebarSpinnerView()
  }

  func updateNSView(_ view: SidebarSpinnerView, context: Context) {
    view.configure(
      font: context.environment.font ?? .body,
      isEmphasized: isEmphasized,
      colorScheme: context.environment.colorScheme,
      scale: context.environment.displayScale
    )
  }
}

@MainActor
final class SidebarSpinnerView: NSView {
  private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  private static let duration: TimeInterval = 0.8
  private struct Appearance: Equatable {
    let font: Font
    let isEmphasized: Bool
    let colorScheme: ColorScheme
    let scale: CGFloat
  }

  private var cachedAppearance: Appearance?
  private let imageLayer = CALayer()
  private var occlusionObserver: NSObjectProtocol?
  private var isAnimating = false

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.addSublayer(imageLayer)
    imageLayer.speed = 0
    setAccessibilityElement(true)
    setAccessibilityLabel("Working")
    setAccessibilityRole(.image)
  }

  required init?(coder: NSCoder) { nil }

  isolated deinit {
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
  }

  func configure(font: Font, isEmphasized: Bool, colorScheme: ColorScheme, scale: CGFloat) {
    let next = Appearance(
      font: font, isEmphasized: isEmphasized, colorScheme: colorScheme, scale: max(1, scale))
    guard cachedAppearance != next else { return }
    let images = Self.frames.compactMap { glyph in
      let renderer = ImageRenderer(
        content: Text(verbatim: glyph)
          .font(font)
          .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
          .environment(\.colorScheme, colorScheme)
          .environment(\.backgroundProminence, isEmphasized ? .increased : .standard)
          .fixedSize()
      )
      renderer.scale = next.scale
      return renderer.cgImage
    }
    guard images.count == Self.frames.count, let first = images.first else { return }
    cachedAppearance = next
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.contents = first
    imageLayer.contentsScale = next.scale
    imageLayer.bounds.size = CGSize(
      width: CGFloat(first.width) / next.scale, height: CGFloat(first.height) / next.scale)
    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = images + [first]
    animation.keyTimes = (0...images.count).map { NSNumber(value: Double($0) / Double(images.count)) }
    animation.calculationMode = .discrete
    animation.duration = Self.duration
    // A nonzero origin prevents Core Animation from substituting add-time;
    // one full period before zero preserves the shared absolute phase.
    animation.beginTime = -Self.duration
    animation.repeatCount = .infinity
    imageLayer.add(animation, forKey: "spinner")
    CATransaction.commit()
    needsLayout = true
    updateAnimationActivity()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    CATransaction.commit()
    updateAnimationActivity()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = nil
    if let window {
      occlusionObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateAnimationActivity() }
      }
    }
    updateAnimationActivity()
  }

  override func viewDidHide() {
    super.viewDidHide()
    updateAnimationActivity()
  }

  override func viewDidUnhide() {
    super.viewDidUnhide()
    updateAnimationActivity()
  }

  private func updateAnimationActivity() {
    let shouldAnimate =
      window.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
      && !isHiddenOrHasHiddenAncestor
    guard shouldAnimate != isAnimating else { return }
    isAnimating = shouldAnimate
    let phase = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.duration)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    imageLayer.speed = shouldAnimate ? 1 : 0
    imageLayer.timeOffset = shouldAnimate ? 0 : phase
    imageLayer.beginTime =
      shouldAnimate
      ? (imageLayer.superlayer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime())
        - phase : 0
    CATransaction.commit()
  }
}
