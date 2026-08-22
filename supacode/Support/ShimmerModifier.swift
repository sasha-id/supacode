import SwiftUI

struct ShimmerModifier: ViewModifier {
  let isActive: Bool
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var size: CGSize = .zero

  func body(content: Content) -> some View {
    if isActive, !MotionPreference.reduceMotion {
      // Measured only here, so an inactive or reduced-motion shimmer costs nothing
      // beyond the plain content. `ShimmerMask` renders fully visible until the
      // first geometry read lands, so re-activating never clips to a stale size.
      content
        .onGeometryChange(for: CGSize.self) {
          $0.size
        } action: {
          size = $0
        }
        // The mask is a single translated gradient, so CoreAnimation composites the sweep on
        // the GPU instead of re-rasterizing the gradient and masked text every frame, as
        // animating the endpoints did.
        .mask(ShimmerMask(size: size, layoutDirection: layoutDirection))
    } else {
      // Reset so a resize while inactive can't mask the next activation to a
      // stale size — activation starts from the fully-visible fallback.
      content.onAppear { size = .zero }
    }
  }
}

/// A shimmer mask whose highlight band moves by translation only. The 0.6 tails keep
/// the whole content visible while the full-opacity band sweeps across, so the mask's
/// alpha stays `0.6 + 0.4 * band` (floor 0.6, peak 1.0), unchanged from the previous mask.
private struct ShimmerMask: View {
  let size: CGSize
  let layoutDirection: LayoutDirection

  // Bright band width as a fraction of the content size.
  private let bandSize: CGFloat = 0.3
  // Track size in content-lengths; the 0.6 tails must cover the content across the whole sweep.
  private let trackScale: CGFloat = 3

  private var gradient: Gradient {
    let half = bandSize / (2 * trackScale)
    return Gradient(stops: [
      .init(color: .black.opacity(0.6), location: 0),
      .init(color: .black.opacity(0.6), location: 0.5 - half),
      .init(color: .black, location: 0.5),
      .init(color: .black.opacity(0.6), location: 0.5 + half),
      .init(color: .black.opacity(0.6), location: 1),
    ])
  }

  var body: some View {
    if size.width <= 0 || size.height <= 0 {
      // Keep the content fully visible before the first geometry read, rather than
      // clipping it to a zero-size mask for a frame.
      Color.black
    } else {
      // The band starts fully off the leading corner and ends fully off the trailing corner.
      let travelX = size.width * (1 + bandSize) / 2
      let travelY = size.height * (1 + bandSize) / 2
      // The gradient is symmetric, so a diagonal axis reproduces the previous corner-to-corner sweep.
      LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
        .frame(width: size.width * trackScale, height: size.height * trackScale)
        // `phaseAnimator` pauses the timeline when the view is occluded, which
        // `.repeatForever` did not.
        .phaseAnimator([false, true]) { band, sweeping in
          band.offset(x: offsetX(sweeping: sweeping, travel: travelX), y: sweeping ? travelY : -travelY)
        } animation: { sweeping in
          sweeping ? .linear(duration: 1.5).delay(0.25) : .linear(duration: 0.001)
        }
    }
  }

  private func offsetX(sweeping: Bool, travel: CGFloat) -> CGFloat {
    if layoutDirection == .rightToLeft {
      return sweeping ? -travel : travel
    }
    return sweeping ? travel : -travel
  }
}

extension View {
  func shimmer(isActive: Bool) -> some View {
    modifier(ShimmerModifier(isActive: isActive))
  }
}
