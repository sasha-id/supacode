import AppKit
import GhosttyKit
import Testing

@testable import supacode

/// End-to-end wiring for the per-surface progress bar: a report ingested by the
/// bridge has to reach the bar the surface wrapper mounts.
@MainActor
struct TerminalSurfaceProgressBarWiringTests {
  private func makeWrapper() -> (GhosttySurfaceView, GhosttySurfaceScrollView) {
    let surfaceView = GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    let wrapper = GhosttySurfaceScrollView(surfaceView: surfaceView)
    wrapper.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    wrapper.layoutSubtreeIfNeeded()
    return (surfaceView, wrapper)
  }

  private func bar(in wrapper: NSView) -> TerminalSurfaceProgressBar? {
    wrapper.subviews.compactMap { $0 as? TerminalSurfaceProgressBar }.first
  }

  @Test func wrapperMountsTheProgressBar() {
    let (_, wrapper) = makeWrapper()
    #expect(bar(in: wrapper) != nil)
  }

  @Test func indeterminateReportRevealsTheBar() async throws {
    let (surfaceView, wrapper) = makeWrapper()
    let progressBar = try #require(bar(in: wrapper))
    #expect(progressBar.isHidden)

    surfaceView.bridge.ingestProgressReport(
      state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    // The observation re-arm hops through a main-actor Task.
    await Task.yield()
    await Task.yield()

    #expect(surfaceView.bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(!progressBar.isHidden)
  }

  @Test func removeHidesTheBarAgain() async throws {
    let (surfaceView, wrapper) = makeWrapper()
    let progressBar = try #require(bar(in: wrapper))

    surfaceView.bridge.ingestProgressReport(
      state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    await Task.yield()
    await Task.yield()
    #expect(!progressBar.isHidden)

    surfaceView.bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    await Task.yield()
    await Task.yield()
    #expect(progressBar.isHidden)
  }
}
