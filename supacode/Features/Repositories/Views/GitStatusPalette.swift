import SwiftUI

/// The hues a worktree row's leading icon and its CI badge are painted in.
///
/// Every token is a system colour pulled toward `.gray`, never a literal. The
/// mix is what keeps the set legible on the flat `sidebarInk` ground: full-chroma
/// system colours are tuned to shout from a toolbar, and a sidebar shows six of
/// them stacked in a column where the loudest one wins the eye regardless of
/// which row actually matters.
///
/// The ratios are not uniform — they are picked so the six land at roughly the
/// same perceived lightness. `.green` and `.yellow` are far brighter than
/// `.purple` at equal chroma, so levelling them takes more gray, and a single
/// shared ratio would just reproduce the original hierarchy at lower saturation.
///
/// `.mix(with:by:)` interpolates perceptually, so a ratio means the same amount
/// of damping whatever the hue it is applied to.
extension ShapeStyle where Self == Color {
  /// CI success. The most common badge by a wide margin, so it takes the
  /// heaviest damping in the set: a passing check is the state you want to be
  /// able to ignore.
  static var checkSuccess: Color { Color.green.mix(with: .gray, by: 0.5) }
  /// CI failure. Damped least of the three — a failed check is the one badge
  /// that has earned the right to pull the eye.
  static var checkFailure: Color { Color.red.mix(with: .gray, by: 0.4) }
  /// CI in progress or queued. `.yellow` is the brightest system colour on a
  /// dark ground, hence the heaviest ratio here.
  static var checkRunning: Color { Color.yellow.mix(with: .gray, by: 0.55) }

  static var pullRequestOpen: Color { Color.green.mix(with: .gray, by: 0.45) }
  /// Merge queue. Replaces `.brown`, which is already a dark, desaturated
  /// orange and so read as dirt rather than as a colour; damped orange lands in
  /// the same part of the wheel while staying a hue.
  static var pullRequestQueued: Color { Color.orange.mix(with: .gray, by: 0.5) }
  static var pullRequestMerged: Color { Color.purple.mix(with: .gray, by: 0.45) }
  static var pullRequestClosed: Color { Color.red.mix(with: .gray, by: 0.45) }
}
