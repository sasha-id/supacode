import DependenciesTestSupport
import Foundation
import GhosttyKit
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct TerminalSurfaceRecipeTests {
  private static func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/recipe-fixture/wt"),
      name: "wt",
      detail: "detail",
      // Explicit hints: fileURLWithPath would stat the path and grow a
      // trailing slash the moment the directory exists on the test machine.
      workingDirectory: URL(filePath: "/tmp/recipe-fixture/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/recipe-fixture", directoryHint: .notDirectory)
    )
  }

  @Test func environmentCarriesIdentityMarkers() {
    let tabID = TabID()
    let surfaceID = UUID()
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: tabID,
      surfaceID: surfaceID,
      socketPath: "/tmp/socket",
      signalSocketPath: "/tmp/signals"
    )
    // Slashes are deliberately encoded: downstream deeplinks embed these IDs.
    #expect(env["SUPACODE_REPO_ID"] == "%2Ftmp%2Frecipe-fixture")
    #expect(env["SUPACODE_WORKTREE_ID"] == "%2Ftmp%2Frecipe-fixture%2Fwt")
    #expect(env["SUPACODE_TAB_ID"] == tabID.rawValue.uuidString)
    #expect(env["SUPACODE_SURFACE_ID"] == surfaceID.uuidString)
    #expect(env["SUPACODE_SOCKET_PATH"] == "/tmp/socket")
    // The control socket is named after the app's pid; this one is not, so an
    // agent that outlives an app restart still has a path somebody listens on.
    #expect(env["SUPACODE_SIGNAL_SOCKET_PATH"] == "/tmp/signals")
    #expect(env["ZMX_DIR"] != nil)
  }

  @Test func environmentOmitsSocketWhenAbsent() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TabID(),
      surfaceID: UUID(),
      socketPath: nil,
      signalSocketPath: nil
    )
    #expect(env["SUPACODE_SOCKET_PATH"] == nil)
    #expect(env["SUPACODE_SIGNAL_SOCKET_PATH"] == nil)
  }

  @Test func extraVariablesCannotOverrideTheZmxDirectoryLock() {
    let env = TerminalSurfaceRecipe.environment(
      for: Self.makeWorktree(),
      tabID: TabID(),
      surfaceID: UUID(),
      socketPath: nil,
      signalSocketPath: nil,
      extraVariables: ["ZMX_DIR": "/evil", "SUPACODE_SCRIPT": "1"]
    )
    #expect(env["ZMX_DIR"] == ZmxSocketBudget.socketDir())
    #expect(env["SUPACODE_SCRIPT"] == "1")
  }

  @Test func bypassingZmxKeepsTheCommandVerbatim() {
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(command: "./script.sh", initialInput: "input\n", bypassZmx: true),
      for: Self.makeWorktree(),
      surfaceID: UUID(),
      zmxExecutablePath: "/usr/local/bin/zmx",
      signalSocketPath: nil
    )
    #expect(launch.command == "./script.sh")
    #expect(launch.initialInput == "input\n")
    #expect(launch.commandWrapper.isEmpty)
    #expect(launch.usesZmx == false)
  }

  @Test func localLaunchDerivesTheSessionFromTheSurfaceID() {
    let surfaceID = UUID()
    let launch = TerminalSurfaceRecipe.launch(
      TerminalSurfaceRecipe.LaunchIntent(),
      for: Self.makeWorktree(),
      surfaceID: surfaceID,
      zmxExecutablePath: "/usr/local/bin/zmx",
      signalSocketPath: nil
    )
    // The session name is the surface identity; hibernated wakes and the CLI
    // both address it by this derivation.
    #expect(launch.usesZmx)
    #expect(launch.commandWrapper.contains(ZmxSessionID.make(surfaceID: surfaceID)))
  }

  @Test(.dependencies) func remoteLaunchForwardsTheSignalSocketOnlyWhenTheSettingAllowsIt() {
    let worktree = Worktree(
      id: WorktreeID("devbox:/srv/wt"),
      name: "wt",
      detail: "detail",
      workingDirectory: URL(filePath: "/srv/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/srv", directoryHint: .notDirectory),
      host: RemoteHost(alias: "devbox")
    )
    func command(forwarding: Bool) -> String {
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global.remoteAgentPresenceForwardingEnabled = forwarding }
      return TerminalSurfaceRecipe.launch(
        TerminalSurfaceRecipe.LaunchIntent(),
        for: worktree,
        surfaceID: UUID(),
        zmxExecutablePath: "/usr/local/bin/zmx",
        signalSocketPath: "/tmp/signals"
      ).command ?? ""
    }
    // Opting out must leave no reverse forward behind: the remote host would
    // otherwise keep a socket into this machine the user asked not to open.
    #expect(command(forwarding: true).contains(":/tmp/signals"))
    #expect(!command(forwarding: false).contains("/tmp/signals"))
  }

  // MARK: - Surface plans.

  private static func makeRequest(
    state: TerminalContentState = TerminalContentState(workingDirectory: nil),
    origin: ContentOrigin = .tab
  ) -> ContentRequest {
    ContentRequest(
      worktreeID: makeWorktree().id,
      tabID: TabID(),
      contentID: ContentID(),
      content: .terminal(state),
      origin: origin
    )
  }

  @Test func planMapsOriginsToSurfaceContexts() {
    let worktree = Self.makeWorktree()
    let state = TerminalContentState(workingDirectory: nil)
    func context(of origin: ContentOrigin) -> ghostty_surface_context_e {
      TerminalSurfaceRecipe.plan(
        for: Self.makeRequest(state: state, origin: origin),
        seed: TerminalSurfaceRecipe.PlanSeed(
          terminalState: state,
          worktree: worktree,
          socketPath: nil,
          signalSocketPath: nil,
          zmxExecutablePath: nil
        )
      ).context
    }
    #expect(context(of: .first) == GHOSTTY_SURFACE_CONTEXT_WINDOW)
    #expect(context(of: .tab) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .restored) == GHOSTTY_SURFACE_CONTEXT_TAB)
    #expect(context(of: .split) == GHOSTTY_SURFACE_CONTEXT_SPLIT)
  }

  @Test func planPrefersThePersistedWorkingDirectory() {
    let worktree = Self.makeWorktree()
    let persistedState = TerminalContentState(workingDirectory: "/tmp/elsewhere")
    let persisted = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(state: persistedState),
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: persistedState,
        worktree: worktree,
        socketPath: nil,
        signalSocketPath: nil,
        zmxExecutablePath: nil
      )
    )
    #expect(persisted.workingDirectory?.path(percentEncoded: false).hasPrefix("/tmp/elsewhere") == true)
    let emptyState = TerminalContentState(workingDirectory: nil)
    let fallback = TerminalSurfaceRecipe.plan(
      for: Self.makeRequest(state: emptyState),
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: emptyState,
        worktree: worktree,
        socketPath: nil,
        signalSocketPath: nil,
        zmxExecutablePath: nil
      )
    )
    #expect(fallback.workingDirectory == worktree.workingDirectory)
  }

  @Test func planCarriesTheFrozenFontAndIdentityEnvironment() throws {
    let worktree = Self.makeWorktree()
    let grid = try #require(
      FrozenGrid.from(backingSize: CGSize(width: 800, height: 600), columns: 80, rows: 24, scale: 2, fontSize: 13)
    )
    let state = TerminalContentState(workingDirectory: nil, frozenGrid: grid)
    let request = Self.makeRequest(state: state, origin: .restored)
    let plan = TerminalSurfaceRecipe.plan(
      for: request,
      seed: TerminalSurfaceRecipe.PlanSeed(
        terminalState: state,
        worktree: worktree,
        socketPath: "/tmp/socket",
        signalSocketPath: nil,
        zmxExecutablePath: "/usr/local/bin/zmx",
        // A frozen grid outranks any fallback font: the frozen backing size
        // only reproduces the grid at the frozen font.
        fallbackFontSize: 99
      )
    )
    #expect(plan.fontSize == 13)
    #expect(plan.environment["SUPACODE_TAB_ID"] == request.tabID.rawValue.uuidString)
    #expect(plan.environment["SUPACODE_SURFACE_ID"] == request.contentID.rawValue.uuidString)
    // The re-attach targets the zmx session derived from the content identity.
    #expect(plan.commandWrapper.contains(ZmxSessionID.make(surfaceID: request.contentID.rawValue)))
  }
}
