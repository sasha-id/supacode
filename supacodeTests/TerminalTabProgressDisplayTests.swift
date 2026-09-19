import GhosttyKit
import Testing

@testable import supacode

/// The OSC-9 projection both the tab stripe and the per-surface progress bar
/// render from.
struct TerminalTabProgressDisplayTests {
  @Test func noReportProducesNoDisplay() {
    #expect(TerminalTabProgressDisplay.make(progressState: nil, progressValue: nil) == nil)
  }

  @Test func removeClearsTheDisplay() {
    let display = TerminalTabProgressDisplay.make(
      progressState: GHOSTTY_PROGRESS_STATE_REMOVE, progressValue: 40)
    #expect(display == nil)
  }

  @Test func errorPauseAndIndeterminateMapToTheirOwnStyles() {
    #expect(
      TerminalTabProgressDisplay.make(progressState: GHOSTTY_PROGRESS_STATE_ERROR, progressValue: nil)?.style
        == .error)
    #expect(
      TerminalTabProgressDisplay.make(progressState: GHOSTTY_PROGRESS_STATE_PAUSE, progressValue: nil)?.style
        == .paused)
    #expect(
      TerminalTabProgressDisplay.make(
        progressState: GHOSTTY_PROGRESS_STATE_INDETERMINATE, progressValue: nil)?.style == .indeterminate)
  }

  /// The bar paints error and paused as a full segment because the percentage
  /// is dropped here; pinning it so a later change to that is a deliberate one.
  @Test func errorAndPauseDiscardTheirPercentage() {
    #expect(
      TerminalTabProgressDisplay.make(progressState: GHOSTTY_PROGRESS_STATE_ERROR, progressValue: 40)?.style
        == .error)
    #expect(
      TerminalTabProgressDisplay.make(progressState: GHOSTTY_PROGRESS_STATE_PAUSE, progressValue: 40)?.style
        == .paused)
  }

  @Test func setWithoutAPercentageIsIndeterminate() {
    let display = TerminalTabProgressDisplay.make(
      progressState: GHOSTTY_PROGRESS_STATE_SET, progressValue: nil)
    #expect(display?.style == .indeterminate)
  }

  @Test(arguments: [
    (0, 0),
    (1, 0),
    (3, 5),
    (47, 45),
    (50, 50),
    (98, 95),
    (100, 100),
    (150, 100),
    (-5, 0),
  ])
  func setBucketsMidRunPercentagesToFiveSteps(input: Int, expected: Int) {
    let display = TerminalTabProgressDisplay.make(
      progressState: GHOSTTY_PROGRESS_STATE_SET, progressValue: input)
    #expect(display?.style == .determinate(percent: expected))
  }

  @Test func severityRanksWorstFirst() {
    let error = TerminalTabProgressDisplay(style: .error)
    let paused = TerminalTabProgressDisplay(style: .paused)
    let determinate = TerminalTabProgressDisplay(style: .determinate(percent: 50))
    let indeterminate = TerminalTabProgressDisplay(style: .indeterminate)
    #expect(error.severity > paused.severity)
    #expect(paused.severity > determinate.severity)
    #expect(determinate.severity > indeterminate.severity)
  }

  @Test func accessibilityValueSpeaksEachStyle() {
    #expect(TerminalTabProgressDisplay(style: .error).accessibilityValue == "Errored")
    #expect(TerminalTabProgressDisplay(style: .paused).accessibilityValue == "Paused")
    #expect(TerminalTabProgressDisplay(style: .indeterminate).accessibilityValue == "Busy")
    #expect(
      TerminalTabProgressDisplay(style: .determinate(percent: 47)).accessibilityValue
        == "47 percent complete")
  }
}
