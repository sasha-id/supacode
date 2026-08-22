import AppKit
import Observation

/// Live mirror of the system Reduce Motion preference
/// (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`), kept as a
/// single `@Observable` instance so a SwiftUI body that reads
/// `MotionPreference.reduceMotion` re-renders when the setting changes.
///
/// Several of the held-still forms consumers fall back to carry less
/// information than the moving ones — a compacting agent badge is
/// indistinguishable from an idle one, a busy tab from a quiet one, and a
/// multi-script group shows one colour instead of cycling all of them.
@MainActor
@Observable
final class MotionPreference {
  static let shared = MotionPreference()

  static var reduceMotion: Bool { shared.reduceMotionValue }

  private(set) var reduceMotionValue: Bool
  @ObservationIgnored private var observer: NSObjectProtocol?

  private init() {
    reduceMotionValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  isolated deinit {
    if let observer {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  private func refresh() {
    reduceMotionValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}
