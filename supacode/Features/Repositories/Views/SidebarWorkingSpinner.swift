import SupacodeSettingsShared
import SwiftUI

/// Braille spinner that stands in for a worktree row's leading icon while an
/// agent is mid-turn or a shell is busy. Ten frames at 80ms, the cadence the
/// same spinner runs at in Superset.
///
/// Driven by a schedule rather than an animation. The frames are discrete —
/// there is nothing to interpolate between two glyphs — so an animator only
/// buys a cross-fade that never lets a frame reach full strength at this
/// cadence, and costs a transaction every 80ms. `TimelineView` just asks which
/// glyph belongs to the current instant and draws it, from one `Text` rather
/// than a stack of ten.
///
/// The frame comes from absolute time, not from a per-instance counter, so rows
/// that started working at different moments still show the same glyph instead
/// of each spinning on its own phase.
///
/// Deliberately **not** gated on Reduce Motion, unlike the decorative ping on
/// these same rows. A frozen spinner reports nothing — it reads as a stray
/// glyph rather than as work in flight — and `NSProgressIndicator` keeps
/// spinning under the setting for exactly that reason. Nothing here translates,
/// scales, or parallaxes, which is the motion the setting exists to suppress.
struct SidebarWorkingSpinner: View {
  private static let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  private static let frameInterval: TimeInterval = 0.08

  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
      Text(verbatim: Self.frame(at: context.date))
        .appFont(.body)
    }
    .foregroundStyle(isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
    .help("Working in this worktree")
    .accessibilityLabel("Working")
  }

  /// No `.monospaced()`: SF Mono carries no braille, so the glyph resolves through
  /// font fallback either way. The whole U+28xx block falls back together in the
  /// default face, and the caller pins the icon slot's width regardless.
  private static func frame(at date: Date) -> String {
    let step = Int(date.timeIntervalSinceReferenceDate / frameInterval)
    return frames[step % frames.count]
  }
}
