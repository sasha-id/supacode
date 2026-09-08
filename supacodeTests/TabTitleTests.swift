import Clocks
import ConcurrencyExtras
import Observation
import Testing

@testable import supacode

/// Locks the title contract now that reported titles live on the content's
/// chrome instead of in `LayoutFeature`: nothing but the chrome carries a
/// terminal's live title, and the layout's own title is the fallback.
@MainActor
struct TabTitleTests {
  private func tab(
    title: String = "Terminal 1",
    customTitle: String? = nil,
    isLocked: Bool = false,
    contentID: ContentID = ContentID()
  ) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      customTitle: customTitle,
      content: ContentSnapshot(
        id: contentID,
        state: .terminal(TerminalContentState(workingDirectory: nil))
      ),
      isLocked: isLocked
    )
  }

  private func chrome(reporting title: String?) -> TerminalTabChrome {
    let chrome = TerminalTabChrome()
    chrome.reportedTitle = title
    return chrome
  }

  @Test func theReportedTitleWinsOverTheLayoutsOwn() {
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: "zsh")) == "zsh")
    #expect(TabTitle.stored(for: tab(), chrome: chrome(reporting: "zsh")) == "zsh")
  }

  @Test func anAbsentOrEmptyReportFallsBackToTheLayoutsTitle() {
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: nil)) == "Terminal 1")
    #expect(TabTitle.resolved(for: tab(), chrome: chrome(reporting: "")) == "Terminal 1")
    #expect(TabTitle.resolved(for: tab(), chrome: nil) == "Terminal 1")
  }

  @Test func aUserOverrideWinsOverTheReportButNeverPersists() {
    let renamed = tab(customTitle: "Custom")
    #expect(TabTitle.resolved(for: renamed, chrome: chrome(reporting: "zsh")) == "Custom")
    // The override persists in its own field; folding it into the stored title
    // would make clearing the rename restore the override text.
    #expect(TabTitle.stored(for: renamed, chrome: chrome(reporting: "zsh")) == "zsh")
  }

  @Test func aLockedTabRefusesTheShellsReport() {
    let script = tab(title: "Setup", isLocked: true)
    #expect(TabTitle.resolved(for: script, chrome: chrome(reporting: "zsh")) == "Setup")
    #expect(TabTitle.stored(for: script, chrome: chrome(reporting: "zsh")) == "Setup")
  }

  @Test func resolvingThroughTheRuntimeReadsTheRegisteredContentsChrome() {
    let contentID = ContentID()
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: contentID)
    _ = runtime.provision(content, at: .fallback)
    content.terminalChrome.reportedTitle = "claude"
    #expect(TabTitle.resolved(for: tab(contentID: contentID), runtime: runtime) == "claude")
  }

  @Test func rapidReportsKeepTheLatestRawTitleWithoutRepublishingEveryIntermediateValue() {
    let chrome = TerminalTabChrome()
    chrome.reportedTitle = "First"
    #expect(TabTitle.resolved(for: tab(), chrome: chrome) == "First")

    chrome.reportedTitle = "Intermediate"
    chrome.reportedTitle = "Latest"

    #expect(TabTitle.stored(for: tab(), chrome: chrome) == "Latest")
    #expect(TabTitle.resolved(for: tab(), chrome: chrome) == "First")
  }

  @Test func sustainedReportsPublishTheLatestValueAtEachBoundedInterval() async throws {
    let clock = TestClock()
    let chrome = TerminalTabChrome(clock: clock)
    chrome.reportedTitle = "First"
    await Task.megaYield()
    chrome.reportedTitle = "Second"
    await clock.advance(by: .milliseconds(249))
    #expect(chrome.presentedTitle == "First")
    chrome.reportedTitle = "Third"
    await clock.advance(by: .milliseconds(1))
    #expect(chrome.presentedTitle == "Third")
    chrome.reportedTitle = "Fourth"
    await Task.megaYield()
    await clock.advance(by: .milliseconds(250))
    #expect(chrome.presentedTitle == "Fourth")
    await clock.advance(by: .milliseconds(250))
    try await clock.checkSuspension()
  }

  @Test func hiddenTitlesStayRawUntilRevealAndSelectionFlushesOnlyOnce() async throws {
    let clock = TestClock()
    let chrome = TerminalTabChrome(clock: clock)
    chrome.reportedTitle = "First"
    chrome.setTitlePresentation(active: false, selected: false)
    chrome.reportedTitle = "Hidden"
    try await clock.checkSuspension()
    #expect(chrome.presentedTitle == "First")
    #expect(chrome.reportedTitle == "Hidden")
    chrome.setTitlePresentation(active: true, selected: false)
    #expect(chrome.presentedTitle == "Hidden")
    chrome.reportedTitle = "Selected"
    chrome.setTitlePresentation(active: true, selected: true)
    #expect(chrome.presentedTitle == "Selected")
    chrome.reportedTitle = "Pending"
    chrome.setTitlePresentation(active: true, selected: true)
    #expect(chrome.presentedTitle == "Selected")
    chrome.setTitlePresentation(active: false, selected: false)
    try await clock.checkSuspension()
  }

  @Test func pendingPublicationDoesNotRetainClosedChrome() async throws {
    let clock = TestClock()
    var chrome: TerminalTabChrome? = TerminalTabChrome(clock: clock)
    weak var weakChrome = chrome
    chrome?.reportedTitle = "First"
    await Task.megaYield()
    chrome = nil
    #expect(weakChrome == nil)
    try await clock.checkSuspension()
  }

  @Test func rawReportsDoNotInvalidateTheObservedLabelAndEmptyTitlesEventuallyClearIt() async throws {
    let clock = TestClock()
    let chrome = TerminalTabChrome(clock: clock)
    chrome.reportedTitle = "First"
    await Task.megaYield()
    let changes = LockIsolated(0)
    withObservationTracking {
      _ = TabTitle.resolved(for: tab(), chrome: chrome)
    } onChange: {
      changes.withValue { $0 += 1 }
    }
    chrome.reportedTitle = "Intermediate"
    chrome.reportedTitle = ""
    #expect(changes.value == 0)
    #expect(TabTitle.stored(for: tab(), chrome: chrome) == "Terminal 1")
    await clock.advance(by: .milliseconds(250))
    #expect(changes.value == 1)
    #expect(TabTitle.resolved(for: tab(), chrome: chrome) == "Terminal 1")
    await clock.advance(by: .milliseconds(250))
    try await clock.checkSuspension()
  }
}
