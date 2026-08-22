import Foundation

/// Build-time stand-in for the system Reduce Motion preference.
///
/// Every guarded animation in the app reads this instead of
/// `@Environment(\.accessibilityReduceMotion)` or
/// `NSWorkspace.accessibilityDisplayShouldReduceMotion`, so motion is governed
/// by one switch in the source rather than by System Settings. Set it to `true`
/// to render every guarded animation in its held-still form.
///
/// Several of those held-still forms carry less information than the moving
/// ones — a compacting agent badge is indistinguishable from an idle one, a
/// busy tab from a quiet one, and a multi-script group shows one colour instead
/// of cycling all of them — which is the reason this is a deliberate switch and
/// not a setting a user can trip without noticing.
enum MotionPreference {
  static let reduceMotion = false
}
