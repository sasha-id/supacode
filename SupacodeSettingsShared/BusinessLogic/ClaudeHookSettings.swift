import Foundation

nonisolated enum ClaudeHookSettings {
  /// Canonical hook map for Claude. One composite command per (event,
  /// matcher) slot keeps the prune-and-replace cycle idempotent.
  static func hooksByEvent() throws -> [String: [JSONValue]] {
    try AgentHookPayloadSupport.extractHookGroups(
      from: ClaudeHooksPayload(),
      invalidConfiguration: ClaudeHookSettingsError.invalidConfiguration
    )
  }
}

nonisolated enum ClaudeHookSettingsError: Error {
  case invalidConfiguration
}

// MARK: - Hook payload.

// Atomic state-set: UserPromptSubmit / PreToolUse / PostToolUse all fire
// `busy`, so activity spans the whole turn the way it does for Codex and Kiro.
// PostToolUse used to fire `idle` on the theory that the 400ms idle debounce in
// WorktreeTerminalManager would bridge the gaps between tools. It doesn't --
// that gap is the model thinking, seconds to tens of seconds -- so a turn read
// as idle from its first finished tool onwards, which is most of its wall time.
// Re-asserting `busy` on PostToolUse also clears the `awaitingInput` set by the
// AskUserQuestion / ExitPlanMode matcher once the user has answered.
// Notification overwrites to `awaitingInput`; Stop and SessionEnd reset to
// `idle`. The pid liveness sweep is the safety net for crashed turns.
private nonisolated struct ClaudeHooksPayload: Encodable {
  static let awaitingInputToolMatcher = "AskUserQuestion|ExitPlanMode"

  private static let busy = AgentHookSettingsCommand.compositeCommand(
    events: [.busy], forwardStdinAsNotification: false, agent: .claude)
  private static let awaitingInputAndNotify = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: true, agent: .claude)
  private static let awaitingInput = AgentHookSettingsCommand.compositeCommand(
    events: [.awaitingInput], forwardStdinAsNotification: false, agent: .claude)
  private static let stop = AgentHookSettingsCommand.claudeStopCommand(agent: .claude)
  // PostCompact is intentionally NOT mapped: compaction finishing is not turn
  // completion. `SessionStart(source: compact)` is what ends the compacting state.
  private static let compacting = AgentHookSettingsCommand.compositeCommand(
    events: [.compacting], forwardStdinAsNotification: false, agent: .claude)
  private static let sessionStart = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionStart], forwardStdinAsNotification: false, agent: .claude)
  private static let sessionEndAndIdle = AgentHookSettingsCommand.compositeCommand(
    events: [.sessionEnd, .idle], forwardStdinAsNotification: false, agent: .claude)

  let hooks: [String: [AgentHookGroup]] = [
    "SessionStart": [
      .init(hooks: [.init(command: Self.sessionStart, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "UserPromptSubmit": [
      .init(hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PreToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)]),
      // Array-order: matched-by-name fires AFTER matcher-"", so awaiting wins.
      .init(
        matcher: Self.awaitingInputToolMatcher,
        hooks: [.init(command: Self.awaitingInput, timeout: AgentHookSettingsCommand.timeoutSeconds)]
      ),
    ],
    "PostToolUse": [
      .init(matcher: "", hooks: [.init(command: Self.busy, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Notification": [
      .init(
        matcher: "",
        hooks: [.init(command: Self.awaitingInputAndNotify, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "PreCompact": [
      .init(hooks: [.init(command: Self.compacting, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "Stop": [
      .init(hooks: [.init(command: Self.stop, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
    "SessionEnd": [
      .init(
        matcher: "", hooks: [.init(command: Self.sessionEndAndIdle, timeout: AgentHookSettingsCommand.timeoutSeconds)])
    ],
  ]
}
