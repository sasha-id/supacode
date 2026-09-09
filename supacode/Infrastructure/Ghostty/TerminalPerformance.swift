import Foundation
import OSLog

/// Opt-in Instruments intervals. No terminal text, paths, or session data is recorded.
nonisolated enum TerminalPerformance {
  static let enabled = ProcessInfo.processInfo.environment["SUPACODE_PROFILE_TERMINAL"] == "1"
  private static let signposter = OSSignposter(subsystem: "app.supabit.supacode", category: "TerminalPerformance")

  static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
    guard enabled else { return nil }
    return signposter.beginInterval(name, id: signposter.makeSignpostID())
  }

  static func end(_ name: StaticString, _ interval: OSSignpostIntervalState?) {
    guard let interval else { return }
    signposter.endInterval(name, interval)
  }
}
