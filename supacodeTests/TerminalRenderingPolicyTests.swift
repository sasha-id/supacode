import Clocks
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct TerminalRenderingPolicyTests {
  @Test func presentationWaitsForDestinationGeometry() async {
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    #expect(presentation.isCovered)
    presentation.frameAvailable(size: CGSize(width: 400, height: 300))
    #expect(presentation.isCovered)
    presentation.frameAvailable(size: CGSize(width: 800, height: 600))
    #expect(!presentation.isCovered)
    await clock.advance(by: .seconds(3))
    #expect(!presentation.showsProgress)
  }

  @Test func residentPresentationDoesNotFlashALoadingCover() {
    let presentation = TerminalPresentation()
    let size = CGSize(width: 800, height: 600)
    presentation.prepare(size: size, cold: true)
    presentation.frameAvailable(size: size)
    presentation.park()
    presentation.prepare(size: size, cold: false)
    #expect(!presentation.isCovered)
  }

  @Test func aWarmSurfaceIsNeverCoveredWhileGeometryMoves() async {
    // Regression: a divider drag relayouts on every mouse event, so the expected
    // size kept moving out from under `frameAvailable` and the cover held for the
    // whole gesture, blanking a pane that already had a perfectly good frame.
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    presentation.frameAvailable(size: CGSize(width: 800, height: 600))
    #expect(!presentation.isCovered)
    for width in stride(from: 810.0, through: 900.0, by: 10.0) {
      presentation.prepare(size: CGSize(width: width, height: 600), cold: false)
      #expect(!presentation.isCovered)
    }
    // No deadline was ever armed, so nothing can fire behind the drag.
    await clock.advance(by: .seconds(3))
    #expect(!presentation.isCovered)
    #expect(!presentation.showsProgress)
  }

  @Test func aSurfaceThatLostItsFrameIsCoveredAgain() {
    // Losing layer contents (a wake, a restore) is the one case that still covers.
    let presentation = TerminalPresentation()
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    presentation.frameAvailable(size: CGSize(width: 800, height: 600))
    presentation.park()
    presentation.prepare(size: CGSize(width: 1000, height: 600), cold: true)
    #expect(presentation.isCovered)
  }

  @Test func loadingIndicatorIsDelayedAndCoverHasABoundedLifetime() async {
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    #expect(!presentation.showsProgress)
    await clock.advance(by: .milliseconds(150))
    #expect(presentation.showsProgress)
    await clock.advance(by: .seconds(2))
    #expect(!presentation.isCovered)
    #expect(!presentation.showsProgress)
  }

  @Test func parkingCancelsDelayedPresentationWork() async {
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    presentation.park()
    await clock.advance(by: .seconds(3))
    #expect(!presentation.showsProgress)
    #expect(!presentation.isCovered)
  }

  @Test func changingGeometryDoesNotExtendTheCoverDeadline() async {
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    await clock.advance(by: .seconds(1))
    presentation.prepare(size: CGSize(width: 1000, height: 600), cold: true)
    presentation.frameAvailable(size: CGSize(width: 800, height: 600))
    #expect(presentation.isCovered)
    await clock.advance(by: .seconds(1))
    #expect(!presentation.isCovered)
    presentation.prepare(size: CGSize(width: 1000, height: 600), cold: true)
    #expect(!presentation.isCovered)
  }

  @Test func parkedTimeoutCannotReleaseANewPresentation() async {
    let clock = TestClock()
    let presentation = TerminalPresentation(clock: clock)
    presentation.prepare(size: CGSize(width: 800, height: 600), cold: true)
    await clock.advance(by: .seconds(1))
    presentation.park()
    presentation.prepare(size: CGSize(width: 1000, height: 600), cold: true)
    await clock.advance(by: .seconds(1))
    #expect(presentation.isCovered)
    presentation.frameAvailable(size: CGSize(width: 1000, height: 600))
    #expect(!presentation.isCovered)
  }

  @Test func resizeSkipsOnlySizesThatWereActuallyApplied() {
    let applied = CGSize(width: 1600, height: 1200)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: applied,
      lastAppliedBackingSize: applied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .skipUnchanged)
  }

  @Test func resizeRejectsDegenerateGridWithoutRecordingIt() {
    let degenerate = CGSize(width: 48, height: 30)
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: degenerate,
      lastAppliedBackingSize: CGSize(width: 1600, height: 1200),
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeBackToPreviouslyRejectedSizeAppliesOnceGridIsViable() {
    // Regression: the old code recorded a rejected size as applied, so a later
    // legitimate resize to the same backing size was skipped forever.
    let size = CGSize(width: 48, height: 40)
    let lastApplied = CGSize(width: 1600, height: 1200)
    let rejected = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(rejected == .rejectDegenerate)
    let retried = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: size,
      lastAppliedBackingSize: lastApplied,
      cellWidth: 8,
      cellHeight: 16
    )
    #expect(retried == .apply)
  }

  @Test func resizeWithUnknownCellMetricsAlwaysApplies() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 2, height: 2),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 0
    )
    #expect(decision == .apply)
  }

  @Test func resizeWithOnlyOneUnknownCellDimensionStillApplies() {
    // Each half of the cell-metric guard must independently short-circuit, or the
    // divisions below it would divide by zero.
    let unknownHeight = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 0
    )
    #expect(unknownHeight == .apply)
    let unknownWidth = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 800, height: 600),
      lastAppliedBackingSize: .zero,
      cellWidth: 0,
      cellHeight: 20
    )
    #expect(unknownWidth == .apply)
  }

  @Test func resizeRejectsWhenOnlyColumnsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 49, height: 100),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeRejectsWhenOnlyRowsAreBelowMinimum() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 100, height: 39),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .rejectDegenerate)
  }

  @Test func resizeAppliesAtExactMinimumGrid() {
    let decision = GhosttySurfaceView.ResizePolicy.decision(
      backingSize: CGSize(width: 50, height: 40),
      lastAppliedBackingSize: .zero,
      cellWidth: 10,
      cellHeight: 20
    )
    #expect(decision == .apply)
  }

}
