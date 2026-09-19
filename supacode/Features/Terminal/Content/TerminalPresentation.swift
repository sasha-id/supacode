import AppKit
import OSLog
import SupacodeSettingsShared

/// Covers a surface that has no frame to show, not the application's ongoing
/// output and not a warm surface whose geometry moved.
/// Each surface owns one instance, so a retired surface cannot reveal its replacement.
@MainActor
final class TerminalPresentation {
  private(set) var isCovered = false
  private(set) var showsProgress = false
  var onChange: (() -> Void)?
  private let clock: any Clock<Duration>
  private var expectedSize: CGSize?
  private var timedOutSize: CGSize?
  private var generation: UInt64 = 0
  private var timeout: Task<Void, Never>?
  private var interval: OSSignpostIntervalState?

  init(clock: any Clock<Duration> = ContinuousClock()) {
    self.clock = clock
  }

  deinit { timeout?.cancel() }

  /// `cold` means the layer holds nothing to present: construction, a wake, or a
  /// restore. A warm surface is never covered. Geometry moves on every event of a
  /// divider drag or a sidebar animation, so `expectedSize` would keep moving out
  /// from under `frameAvailable` and the cover would hold for the whole gesture;
  /// letting the last frame stretch for a refresh reads far better than blanking
  /// a terminal that already has content.
  func prepare(size: CGSize, cold: Bool) {
    guard size.width > 0, size.height > 0 else { return }
    expectedSize = size
    guard cold, timedOutSize != size else { return }
    // Geometry can move repeatedly while covered; it must not restart the deadline.
    guard !isCovered else { return }
    isCovered = true
    interval = TerminalPerformance.begin("First frame availability")
    showsProgress = false
    generation &+= 1
    let token = generation
    onChange?()
    timeout = Task { [weak self, clock] in
      do {
        try await clock.sleep(for: .milliseconds(150))
        guard let self, self.generation == token else { return }
        self.showsProgress = true
        self.onChange?()
        try await clock.sleep(for: .milliseconds(1850))
        guard self.generation == token else { return }
        self.timedOutSize = self.expectedSize
        SupaLogger("TerminalPresentation").warning("First frame timed out; releasing presentation cover")
        self.finish()
      } catch {}
    }
  }

  func frameAvailable(size: CGSize) {
    guard size == expectedSize else { return }
    timedOutSize = nil
    if isCovered { finish() }
  }

  func park() {
    timedOutSize = nil
    finish()
  }

  private func finish() {
    TerminalPerformance.end("First frame availability", interval)
    interval = nil
    generation &+= 1
    timeout?.cancel()
    timeout = nil
    isCovered = false
    showsProgress = false
    onChange?()
  }
}
