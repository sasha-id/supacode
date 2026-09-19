import Combine
import Foundation
import Observation
import Sharing
import SupacodeSettingsShared

/// Live mirror of the app's own Animations setting
/// (`GlobalSettings.animationsEnabled`), kept as a single `@Observable`
/// instance so a SwiftUI body that reads `MotionPreference.reduceMotion`
/// re-renders when the setting changes.
///
/// Deliberately the app's switch rather than the system Reduce Motion
/// preference: several of the held-still forms consumers fall back to carry
/// less information than the moving ones — a compacting agent badge is
/// indistinguishable from an idle one, a busy tab from a quiet one, and a
/// multi-script group shows one colour instead of cycling all of them — so
/// this stays a choice the user makes for Supacode alone.
@MainActor
@Observable
final class MotionPreference {
  static let shared = MotionPreference()

  static var reduceMotion: Bool { !shared.animationsEnabled }

  /// Seeded at the declaration, not in `init`, so the stored properties are all
  /// initialized before the initializer reads `settingsFile` off `self`.
  private(set) var animationsEnabled = GlobalSettings.default.animationsEnabled
  @ObservationIgnored
  @Shared(.settingsFile) private var settingsFile: SettingsFile
  @ObservationIgnored private var subscription: AnyCancellable?

  private init() {
    animationsEnabled = settingsFile.global.animationsEnabled
    // A key-path map keeps the transform nonisolated: the publisher emits off
    // the main actor, so a main-actor-isolated inline closure would trap.
    subscription = $settingsFile.publisher
      .map(\.global.animationsEnabled)
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] enabled in
        MainActor.assumeIsolated {
          self?.animationsEnabled = enabled
        }
      }
  }
}
