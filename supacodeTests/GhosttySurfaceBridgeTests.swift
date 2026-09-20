import Clocks
import ConcurrencyExtras
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

// Serialized: the coalescing tests drive a TestClock from the throttle task;
// parallel execution can race `advance` before a task suspends and flake.
@MainActor
@Suite(.serialized)
struct GhosttySurfaceBridgeTests {
  /// Yields enough for a freshly spawned throttle task to register its sleep
  /// with the TestClock before advancing past it.
  private func settleThenAdvance(_ clock: TestClock<Duration>, by duration: Duration) async {
    await Task.megaYield()
    await clock.advance(by: duration)
  }

  /// Advances in bounded ticks until `condition` holds: a freshly spawned task
  /// can register its sleep after a single advance under load, so one tick
  /// isn't guaranteed to be enough. The bound only guards a regression from
  /// spinning forever.
  private func settleThenAdvance(
    _ clock: TestClock<Duration>,
    by duration: Duration,
    until condition: () -> Bool
  ) async {
    for _ in 0..<50 where !condition() {
      await settleThenAdvance(clock, by: duration)
    }
  }

  @Test
  func openUrlRequestPreservesHTTPSURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "https://supacode.dev/changelog",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.kind == .unknown)
    #expect(request?.url.absoluteString == "https://supacode.dev/changelog")
    #expect(request?.url.isFileURL == false)
  }

  @Test
  func openUrlRequestTreatsTildePathAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "~/code/github.com/supabitapp/supacode",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(
      request?.url.path
        == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "code/github.com/supabitapp/supacode").path
    )
  }

  @Test
  func openUrlRequestExpandsNamedTildePathAsFileURL() {
    let username = NSUserName()
    let input = "~\(username)/code/github.com/supabitapp/supacode"
    let request = ghosttyOpenURLRequest(
      urlString: input,
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == NSString(string: input).expandingTildeInPath)
  }

  @Test
  func openUrlRequestTreatsPlainPathWithSpacesAsFileURL() {
    let request = ghosttyOpenURLRequest(
      urlString: "/tmp/supa code/output.txt",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT
    )

    #expect(request?.kind == .text)
    #expect(request?.url.isFileURL == true)
    #expect(request?.url.path == "/tmp/supa code/output.txt")
  }

  @Test
  func openUrlRequestTreatsUnknownStringAsFilePath() {
    let request = ghosttyOpenURLRequest(
      urlString: "relative/path",
      kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
    )

    #expect(request?.url.isFileURL == true)
  }

  @Test
  func openUrlReturnsHandledResult() {
    let bridge = GhosttySurfaceBridge()
    let target = ghostty_target_s(tag: GHOSTTY_TARGET_SURFACE, target: .init())

    withOpenURLAction(url: "/tmp/test") { action in
      #expect(bridge.handleAction(target: target, action: action))
      #expect(bridge.state.openUrl == "/tmp/test")
      #expect(bridge.state.openUrlKind == action.action.open_url.kind)
    }
  }

  // A true return tells core a native child-exited UI was shown, which is
  // what keeps it from printing "Process exited. Press any key to close the
  // terminal." into the grid during the probe-then-close window.
  @Test func routineChildExitClaimsCoreNotice() {
    let bridge = GhosttySurfaceBridge()
    var exitCode: UInt32?
    bridge.onChildExited = { exitCode = $0 }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_SHOW_CHILD_EXITED
    action.action.child_exited = ghostty_surface_message_childexited_s(exit_code: 0, timetime_ms: 5000)

    #expect(bridge.handleAction(target: ghostty_target_s(), action: action))
    #expect(exitCode == 0)
    #expect(bridge.state.childExitTimeMs == 5000)
  }

  // At or below core's 250ms abnormal-exit threshold the surface stays open,
  // so core's in-terminal diagnostics must be allowed to paint.
  @Test func abnormalChildExitLeavesCoreDiagnosticsToPaint() {
    let bridge = GhosttySurfaceBridge()
    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_SHOW_CHILD_EXITED
    action.action.child_exited = ghostty_surface_message_childexited_s(exit_code: 1, timetime_ms: 250)

    #expect(!bridge.handleAction(target: ghostty_target_s(), action: action))
  }

  @Test func desktopNotificationEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var received: (title: String, body: String)?
    bridge.onDesktopNotification = { title, body in
      received = (title, body)
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
    let target = ghostty_target_s()

    "Title".withCString { titlePtr in
      "Body".withCString { bodyPtr in
        action.action.desktop_notification = ghostty_action_desktop_notification_s(
          title: titlePtr,
          body: bodyPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(received?.title == "Title")
    #expect(received?.body == "Body")
  }

  @Test func contextSignalEmitsCallback() {
    let bridge = GhosttySurfaceBridge()
    var receivedAction: UInt8?
    var receivedID: String?
    var receivedMetadata: String?
    bridge.onContextSignal = { action, id, metadata in
      receivedAction = action
      receivedID = id
      receivedMetadata = metadata
    }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    "claude".withCString { idPtr in
      "event=busy".withCString { metaPtr in
        action.action.context_signal = ghostty_action_context_signal_s(
          action: 0,
          id: idPtr,
          metadata: metaPtr
        )
        _ = bridge.handleAction(target: target, action: action)
      }
    }

    #expect(receivedAction == 0)
    #expect(receivedID == "claude")
    #expect(receivedMetadata == "event=busy")
  }

  @Test func contextSignalDropsNullIDOrMetadata() {
    let bridge = GhosttySurfaceBridge()
    var invoked = false
    bridge.onContextSignal = { _, _, _ in invoked = true }

    var action = ghostty_action_s()
    action.tag = GHOSTTY_ACTION_CONTEXT_SIGNAL
    let target = ghostty_target_s()

    // Null id with valid metadata.
    "event=busy".withCString { metaPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: nil,
        metadata: metaPtr
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)

    // Valid id with null metadata.
    "claude".withCString { idPtr in
      action.action.context_signal = ghostty_action_context_signal_s(
        action: 0,
        id: idPtr,
        metadata: nil
      )
      _ = bridge.handleAction(target: target, action: action)
    }
    #expect(invoked == false)
  }

  @Test func coalescesBurstOfProgressReports() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    // Leading edge applies the first report immediately; the rest coalesce.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 20)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    #expect(bridge.state.progressValue == 10)
    #expect(callbackCount == 1)

    // One throttle tick flushes only the latest coalesced value. Extra ticks
    // can't over-fire the callback: a flush task that wakes with nothing
    // pending exits without applying or rescheduling.
    await settleThenAdvance(clock, by: .milliseconds(50)) { bridge.state.progressValue == 50 }
    #expect(bridge.state.progressValue == 50)
    #expect(callbackCount == 2)
  }

  /// The regression that hid every bar: Claude Code reports OSC-9 once per turn
  /// and holds, so a bar that expires on its own silence is a bar nobody sees.
  /// Only the emitter's REMOVE, or the command ending, may take it down.
  @Test func aHeldReportSurvivesArbitrarySilence() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    // Minutes of silence, well past any plausible timeout.
    for _ in 0..<10 {
      await settleThenAdvance(clock, by: .seconds(60))
    }
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func commandFinishedClearsAHeldBar() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    _ = bridge.handleAction(target: ghostty_target_s(), action: commandFinishedAction(exitCode: 0))
    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  @Test func childExitedClearsAHeldBar() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 42)
    #expect(bridge.state.progressValue == 42)

    _ = bridge.handleAction(target: ghostty_target_s(), action: childExitedAction(exitCode: 1))
    #expect(bridge.state.progressState == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  /// Shell integration fires COMMAND_FINISHED on every prompt; a surface that
  /// never reported progress must not wake the downstream running-state work.
  @Test func commandFinishedWithoutProgressStaysSilent() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    _ = bridge.handleAction(target: ghostty_target_s(), action: commandFinishedAction(exitCode: 0))
    _ = bridge.handleAction(target: ghostty_target_s(), action: childExitedAction(exitCode: 0))
    #expect(callbackCount == 0)
  }

  @Test func progressDriverRestartsAfterRemoval() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    #expect(bridge.state.progressState == nil)

    // A report after the REMOVE must re-arm the driver, not freeze.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    #expect(bridge.state.progressValue == 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 60)
    await settleThenAdvance(clock, by: .milliseconds(50)) { bridge.state.progressValue == 60 }
    #expect(bridge.state.progressValue == 60)
  }

  @Test func determinateValuePaintsPromptlyAfterIdlePeriod() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    bridge.onProgressReport = { _ in }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 10)
    #expect(bridge.state.progressValue == 10)

    // Sit idle past the throttle window, then a fresh value must paint on its
    // leading edge instead of waiting for a tick. Drain the in-flight flush
    // first so the leading-edge gate is actually open.
    await settleThenAdvance(clock, by: .milliseconds(50)) { bridge.isProgressFlushIdleForTesting }
    #expect(bridge.state.progressValue == 10)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    #expect(bridge.state.progressValue == 80)
  }

  @Test func identicalReportsNeverReapply() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    var callbackCount = 0
    bridge.onProgressReport = { _ in callbackCount += 1 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
    #expect(callbackCount == 1)

    // A flood of identical reports never re-applies, so the downstream callback
    // fires exactly once across the whole stream.
    for _ in 0..<10 {
      bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_INDETERMINATE, value: nil)
      await settleThenAdvance(clock, by: .milliseconds(50))
    }
    #expect(callbackCount == 1)
    #expect(bridge.state.progressState == GHOSTTY_PROGRESS_STATE_INDETERMINATE)
  }

  @Test func removeWinsOverUnappliedTrailingValue() {
    let bridge = GhosttySurfaceBridge(
      clock: TestClock(), progressThrottleInterval: .milliseconds(50))
    var states: [ghostty_action_progress_report_state_e] = []
    bridge.onProgressReport = { states.append($0) }

    // First SET applies on the leading edge; the second sits un-applied in
    // pendingProgress because no throttle tick has fired yet.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 100)
    // REMOVE before the tick drops the trailing 100 and clears.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)

    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(states == [GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_REMOVE])
  }

  @Test func removeRacingRescheduleKeepsFlushHealthy() async {
    let clock = TestClock()
    let bridge = GhosttySurfaceBridge(clock: clock, progressThrottleInterval: .milliseconds(50))
    var applied: [Int?] = []
    bridge.onProgressReport = { state in
      if state != GHOSTTY_PROGRESS_STATE_REMOVE { applied.append(bridge.state.progressValue) }
    }

    // REMOVE cancels the in-flight flush task while a new run starts at once.
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 50)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 80)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 30)
    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 90)

    // The cancelled task resuming must not clobber the new run's flush handle:
    // before any tick only the leading edges (50, then 30 after the REMOVE)
    // have applied; a clobber would leading-apply the trailing 90 early.
    await Task.megaYield()
    #expect(applied == [50, 30])

    // Then each distinct value flushes exactly once, with no redundant re-apply.
    await settleThenAdvance(clock, by: .milliseconds(50)) { bridge.state.progressValue == 90 }
    #expect(bridge.state.progressValue == 90)
    #expect(applied == [50, 30, 90])
  }

  @Test func removeReportClearsImmediately() {
    let bridge = GhosttySurfaceBridge(clock: TestClock())
    var lastState: ghostty_action_progress_report_state_e?
    bridge.onProgressReport = { lastState = $0 }

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_SET, value: 42)
    #expect(bridge.state.progressValue == 42)

    bridge.ingestProgressReport(state: GHOSTTY_PROGRESS_STATE_REMOVE, value: nil)
    #expect(bridge.state.progressState == nil)
    #expect(bridge.state.progressValue == nil)
    #expect(lastState == GHOSTTY_PROGRESS_STATE_REMOVE)
  }

  private func commandFinishedAction(exitCode: Int16) -> ghostty_action_s {
    var action = ghostty_action_s(tag: GHOSTTY_ACTION_COMMAND_FINISHED, action: .init())
    action.action.command_finished = ghostty_action_command_finished_s(
      exit_code: exitCode, duration: 0)
    return action
  }

  private func childExitedAction(exitCode: UInt32) -> ghostty_action_s {
    var action = ghostty_action_s(tag: GHOSTTY_ACTION_SHOW_CHILD_EXITED, action: .init())
    action.action.child_exited = ghostty_surface_message_childexited_s(
      exit_code: exitCode, timetime_ms: 0)
    return action
  }

  private func withOpenURLAction<T>(
    url: String,
    kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
    _ body: (ghostty_action_s) -> T
  ) -> T {
    var action = ghostty_action_s(tag: GHOSTTY_ACTION_OPEN_URL, action: .init())
    action.action.open_url.kind = kind
    guard let pointer = strdup(url) else {
      Issue.record("strdup failed")
      return body(action)
    }
    defer {
      free(pointer)
    }
    action.action.open_url.url = UnsafePointer(pointer)
    action.action.open_url.len = UInt(strlen(pointer))
    return body(action)
  }
}
