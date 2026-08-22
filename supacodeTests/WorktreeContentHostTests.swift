import AppKit
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeContentHostTests {
  private func makeWorktree(id: String = "/tmp/repo/wt-host") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Tab",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  private func makeHost(layout: PaneLayout?, runtime: ContentRuntime = ContentRuntime()) -> WorktreeContentHost {
    let host = WorktreeContentHost(
      worktree: makeWorktree(),
      runtime: runtime,
      clock: ContinuousClock(),
      runSetupScript: false
    )
    host.layout = { layout }
    return host
  }

  private func append(_ titles: some Sequence<String>, to host: WorktreeContentHost, surfaceID: UUID) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      for title in titles {
        host.appendNotification(title: title, body: "body", surfaceID: surfaceID)
      }
    }
  }

  @Test(.dependencies) func retentionTrimKeepsTheNewestUnread() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...100).map { "N\($0)" }, to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // Every entry is unread, so the OLDEST drops and the newest survives.
    #expect(host.notifications.first?.title == "N100")
    #expect(!host.notifications.contains { $0.title == "N0" })
  }

  @Test(.dependencies) func retentionTrimDropsReadBeforeUnreadRegardlessOfAge() throws {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.notificationRetentionLimit = .oneHundred }
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    host.registerSurfaceState(for: surfaceID)

    append((0...99).map { "N\($0)" }, to: host, surfaceID: surfaceID)
    let read = try #require(host.notifications.first { $0.title == "N50" })
    host.markNotificationRead(id: read.id)
    append(["N100"], to: host, surfaceID: surfaceID)

    #expect(host.notifications.count == 100)
    // The read entry goes first, even though older unread entries exist.
    #expect(!host.notifications.contains { $0.title == "N50" })
    #expect(host.notifications.contains { $0.title == "N0" })
    #expect(host.notifications.first?.title == "N100")
  }

  @Test(.dependencies) func unseenCounterCountsFromRegistrationAtProvision() {
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))
    // Provision-time registration: without it the increment would no-op.
    host.registerSurfaceState(for: surfaceID)

    append(["Ping"], to: host, surfaceID: surfaceID)

    #expect(host.surfaceStates[surfaceID]?.unseenNotificationCount == 1)
    #expect(host.hasUnseenNotification)
  }

  @Test(.dependencies) func blockingScriptCompletionLocksTheTabChrome() {
    let surfaceID = UUID()
    let tabID = TabID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)

    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)

    host.handleBlockingScriptCommandFinished(tabID: tabID, exitCode: 0)
    #expect(content.terminalChrome.isReadOnly)

    // Re-running the script unlocks the parked shell's replacement.
    host.trackBlockingScript(kind: .archive, tabID: tabID, launchDirectory: nil)
    #expect(content.terminalChrome.isReadOnly == false)
  }

  @Test(.dependencies) func aReportedTitleLandsOnTheChromeAndRearmsPersistenceOnce() {
    let surfaceID = UUID()
    let contentID = ContentID(rawValue: surfaceID)
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    #expect(runtime.provision(content, at: .fallback))
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID), runtime: runtime)
    var sentLayoutActions = 0
    var persistenceRearms = 0
    host.sendLayoutAction = { _ in sentLayoutActions += 1 }
    host.onReportedTitleChanged = { persistenceRearms += 1 }

    host.updateReportedTitle(for: contentID, title: "claude")
    // An unchanged report is dropped before it can touch the chrome.
    host.updateReportedTitle(for: contentID, title: "claude")

    #expect(content.terminalChrome.reportedTitle == "claude")
    #expect(persistenceRearms == 1)
    // The whole point: a title storm never reaches the store.
    #expect(sentLayoutActions == 0)
  }

  @Test func theFocusedContentReclaimsFirstResponderOnlyWhileSelected() {
    let surfaceID = UUID()
    let host = makeHost(layout: singleTabLayout(contentID: surfaceID))

    host.isSelected = { true }
    #expect(host.shouldClaimFocus(surfaceID))

    // A deselected worktree keeps its tree mounted, so a remount inside it must
    // not pull first responder off the worktree on screen.
    host.isSelected = { false }
    #expect(!host.shouldClaimFocus(surfaceID))
  }

  @Test func aWindowedPaneReclaimsFirstResponderWhileTheWorktreeIsDeselected() {
    let surfaceID = UUID()
    let layout = singleTabLayout(contentID: surfaceID)
    let host = makeHost(layout: layout)
    let paneID = layout.panes[0].id

    host.isSelected = { false }
    host.windowedPaneIDs = { [paneID] }

    // The pane owns its own window's focus, whichever worktree is selected.
    #expect(host.shouldClaimFocus(surfaceID))
  }
}

/// Pins the render-host claim invariants the steal-proof mount depends on.
@MainActor
struct WorktreeContentRuntimeRenderHostTests {
  @Test func aNewerClaimInvalidatesTheOlderOne() {
    let runtime = ContentRuntime()
    let contentID = ContentID()
    let first = runtime.claimRenderHost(for: contentID)
    #expect(runtime.isCurrentRenderHost(first, for: contentID))
    let second = runtime.claimRenderHost(for: contentID)
    #expect(!runtime.isCurrentRenderHost(first, for: contentID))
    #expect(runtime.isCurrentRenderHost(second, for: contentID))
  }

  @Test func aClaimSurvivesRemovalForTheReattachFlow() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    // Reattach removes and re-provisions the same ID under the live host.
    runtime.remove(content.id, tombstone: false)
    #expect(runtime.isCurrentRenderHost(claim, for: content.id))
  }

  @Test func confirmKillReleasesTheClaim() {
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID())
    #expect(runtime.provision(content, at: .fallback))
    let claim = runtime.claimRenderHost(for: content.id)
    runtime.remove(content.id, tombstone: true)
    runtime.confirmKill(content.id)
    #expect(!runtime.isCurrentRenderHost(claim, for: content.id))
  }
}
