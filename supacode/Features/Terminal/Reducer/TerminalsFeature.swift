import Combine
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// How much of the app-shell layout-changed work a layout action can invalidate.
nonisolated enum LayoutChangeScope: Equatable, Sendable {
  /// Topology, tab visibility, pane focus, or the live surface set may have moved.
  case structural
  /// Only per-layout bookkeeping changed (split ratios, reported titles, the
  /// inline rename field), so nothing but the persisted snapshot is stale.
  case bookkeeping
}

/// App-shell side effects of a layout change (persistence debounce, sidebar
/// projection, dormant watchers); the integration layer injects the live hook.
nonisolated struct LayoutChangeObserver: Sendable {
  var layoutChanged: @MainActor @Sendable (Worktree.ID, LayoutChangeScope) -> Void
}

extension LayoutChangeObserver: DependencyKey {
  static let liveValue = LayoutChangeObserver(layoutChanged: { _, _ in })
  static let testValue = liveValue
}

/// Owns the per-worktree `LayoutFeature` collection and the visibility-driven
/// hibernation sweep. Views scope through
/// `store.scope(state: \.terminals, action: \.terminals)` so terminal surface
/// area stays bounded to terminal state instead of the whole app.
@Reducer
struct TerminalsFeature {
  /// Grace window a tab must stay hidden before it hibernates.
  static let hibernationGraceWindow: Duration = .seconds(5 * 60)

  /// Per-tab cancellation key for the hibernation grace timer.
  nonisolated enum HibernationTimerID: Hashable, Sendable {
    case tab(TabID)
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case memoryPressure
  }

  @ObservableState
  struct State: Equatable {
    /// Per-worktree pane and tab topology, hydrated from `layouts.json` v2.
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    /// True when the persisted file was written by a newer schema; its records
    /// are served but must never be written back.
    var layoutsAreReadOnly = false
    /// The selected worktree; only its panes' selected tabs are visible, so
    /// everything else is a hibernation candidate.
    var selectedWorktreeID: Worktree.ID?
    /// Most-recently-selected worktrees, newest first, within the optional
    /// renderer retention budget. Their visible panes' selected tabs never arm a
    /// grace timer, so switching back among them is a visibility change.
    var recentWorktreeIDs: [Worktree.ID] = []
    /// Tabs with an armed hibernation grace timer.
    var hibernationArmedTabs: Set<TabID> = []
    /// Hidden-but-ineligible tabs already logged, so a permanently ineligible
    /// tab does not spam every grace-window re-fire.
    var hibernationDeferralLogged: Set<TabID> = []
    /// Visible tabs already sent a wake; cleared when the renderer appears or
    /// the tab hides again, so a failed wake cannot loop.
    var wakeRequestedTabs: Set<TabID> = []
  }

  enum Action {
    case layouts(IdentifiedActionOf<LayoutFeature>)
    /// Subscribes the process-wide sources the hibernation policy reads.
    case task
    /// The migrated layouts file finished loading. Consistent records become
    /// `LayoutFeature` states; inconsistent ones fall back to a fresh layout
    /// on first use.
    case layoutsHydrated(LayoutsFile)
    /// Ensures a layout exists for a worktree and carries its display name for
    /// minted tab titles. Never replaces a live layout.
    case attachLayout(worktreeID: Worktree.ID, titlePrefix: String)
    /// Drops a pruned worktree's layout and bookkeeping.
    case detachLayout(worktreeID: Worktree.ID)
    /// Worktree selection moved; visibility-driven hibernation re-diffs and
    /// the newly visible selection wakes.
    case selectedWorktreeChanged(Worktree.ID?)
    /// The hibernation Beta flag flipped: enabling re-arms hidden tabs,
    /// disabling cancels every pending timer.
    case hibernationPolicyChanged
    /// A tab's grace timer fired; re-verify and hibernate or re-arm.
    case hibernationGraceElapsed(worktreeID: Worktree.ID, tabID: TabID)
    /// The system reported memory pressure: drop the recency budget to the
    /// selection and hibernate every hidden tab now, skipping the clock.
    case memoryPressureWarning
  }

  private static let logger = SupaLogger("TerminalsFeature")

  // Ratio drags and the inline rename field arrive at high frequency, and a
  // teardown title commit only relabels a tab; none of them flips tab
  // visibility or anything the app-shell hooks re-derive, so skip the
  // layout-wide re-diff and the heavy hooks for them. Exhaustive so a new
  // action has to declare itself; classify as `.structural` when unsure.
  static func changeScope(_ action: LayoutFeature.Action) -> LayoutChangeScope {
    switch action {
    case .resizePane, .beginTabRename, .endTabRename, .cancelWake, .runtime(.titleCommitted):
      return .bookkeeping
    case .newTab, .splitPane, .closeTab, .closePane, .selectTab, .renameTab, .focusPane,
      .moveTab, .moveTabToSplit, .moveTabToSpanningSplit, .enterWindowMode, .exitWindowMode,
      .equalizePanes, .toggleZoom, .hibernateTab, .wakeTab, .runtime(.killConfirmed),
      .runtime(.wakeCompleted),
      .contentRequestedClose, .contentRequestedNewTab, .contentRequestedSplit,
      .contentRequestedFocus, .contentRequestedFocusSplit, .contentRequestedToggleZoom,
      .contentRequestedResize, .contentRequestedGotoTab, .contentRequestedMoveTab, .alert:
      return .structural
    }
  }

  @Dependency(ContentRuntime.self) private var contentRuntime
  @Dependency(ContentRetentionPolicy.self) private var retentionPolicy
  @Dependency(LayoutChangeObserver.self) private var layoutChangeObserver
  @Dependency(MemoryPressureClient.self) private var memoryPressure
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // Capture removed tabs before forEach runs the element reducer. Cleanup
      // must include their timers without walking unrelated worktrees.
      let previousTabs: Set<TabID>
      switch action {
      case .layouts(.element(_, .hibernateTab(let tabID))):
        previousTabs = [tabID]
      case .layouts(.element(let id, let action)) where Self.changeScope(action) == .structural:
        previousTabs = Set(state.layouts[id: id]?.layout.panes.flatMap(\.tabs.ids) ?? [])
      case .detachLayout(let id):
        previousTabs = Set(state.layouts[id: id]?.layout.panes.flatMap(\.tabs.ids) ?? [])
      default:
        previousTabs = []
      }
      return reconciledReducer(previousTabs: previousTabs).reduce(into: &state, action: action)
    }
  }

  private func reconcileLayoutChange(
    _ state: inout State, worktreeID: Worktree.ID, action: LayoutFeature.Action, previousTabs: Set<TabID>
  ) -> Effect<Action> {
    // The element reducer already ran; any topology change may flip tab
    // visibility, so re-diff the grace timers and fire the app-shell
    // hooks (persistence debounce, sidebar projection).
    let scope = Self.changeScope(action)
    var timerCleanup: Effect<Action> = .none
    var completedHibernation: TabID?
    if case .hibernateTab(let tabID) = action {
      completedHibernation = tabID
      // A completed hibernate has no work for a grace timer. A refused
      // hibernate can re-arm below while its renderer remains live.
      state.hibernationDeferralLogged.remove(tabID)
      if state.hibernationArmedTabs.remove(tabID) != nil {
        timerCleanup = .cancel(id: HibernationTimerID.tab(tabID))
      }
    }
    let hibernation =
      scope == .structural
      ? reconcileHibernation(
        &state, affectedWorktrees: [worktreeID], previousTabs: previousTabs,
        onlyTab: completedHibernation)
      : .none
    return .concatenate(
      timerCleanup,
      .merge(
        hibernation,
        .run { _ in await layoutChangeObserver.layoutChanged(worktreeID, scope) }
      )
    )
  }

  private func reconciledReducer(previousTabs: Set<TabID>) -> some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .layouts(.element(let worktreeID, let action)):
        return reconcileLayoutChange(&state, worktreeID: worktreeID, action: action, previousTabs: previousTabs)

      case .layouts, .hibernationPolicyChanged:
        return reconcileHibernation(&state)

      case .task:
        return .run { [memoryPressure] send in
          for await _ in memoryPressure.warnings() {
            await send(.memoryPressureWarning)
          }
        }
        .cancellable(id: CancelID.memoryPressure, cancelInFlight: true)

      case .attachLayout(let worktreeID, let titlePrefix):
        if state.layouts[id: worktreeID] == nil {
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: PaneLayout()))
        }
        state.layouts[id: worktreeID]?.titlePrefix = titlePrefix
        return .none

      case .detachLayout(let worktreeID):
        // Bookkeeping is NOT pre-cleared: the reconcile below must still see
        // the armed entries to emit their timer cancellations.
        state.layouts.remove(id: worktreeID)
        state.recentWorktreeIDs.removeAll { $0 == worktreeID }
        return reconcileHibernation(&state, affectedWorktrees: [worktreeID], previousTabs: previousTabs)

      case .selectedWorktreeChanged(let worktreeID):
        let previousSelection = state.selectedWorktreeID
        state.selectedWorktreeID = worktreeID
        Self.recordSelection(worktreeID, in: &state.recentWorktreeIDs)
        return reconcileHibernation(
          &state,
          affectedWorktrees: previousSelection.map { Set([$0, worktreeID].compactMap { $0 }) }
        )

      case .hibernationGraceElapsed(let worktreeID, let tabID):
        return reduceHibernationGraceElapsed(&state, worktreeID: worktreeID, tabID: tabID)

      case .memoryPressureWarning:
        return reduceMemoryPressureWarning(&state)

      case .layoutsHydrated(let file):
        state.layoutsAreReadOnly = file.schemaVersion > LayoutsFile.currentSchemaVersion
        // The runtime keys globally by content id and hibernation by tab id, so
        // seed from what is already hydrated and refuse any record that reuses an
        // id from another worktree (possible in pre-creation-gate layouts).
        var seenContentIDs = Set(state.layouts.flatMap { $0.layout.allContentIDs })
        var seenTabIDs = Set(state.layouts.flatMap { $0.layout.panes.flatMap(\.tabs.ids) })
        for (key, record) in file.worktrees.sorted(by: { $0.key < $1.key }) {
          guard record.layout.isConsistent else {
            Self.logger.error("Dropping inconsistent persisted layout for \(key)")
            continue
          }
          let contentIDs = record.layout.allContentIDs
          let tabIDs = record.layout.panes.flatMap(\.tabs.ids)
          guard seenContentIDs.isDisjoint(with: contentIDs), seenTabIDs.isDisjoint(with: tabIDs) else {
            Self.logger.error("Dropping persisted layout for \(key): an id collides with another worktree")
            continue
          }
          let worktreeID = Worktree.ID(key)
          guard state.layouts[id: worktreeID] == nil else { continue }
          state.layouts.append(LayoutFeature.State(id: worktreeID, layout: record.layout))
          seenContentIDs.formUnion(contentIDs)
          seenTabIDs.formUnion(tabIDs)
        }
        // Hydration can land after the first selection; re-diff so the
        // restored hidden tabs arm and the visible selection wakes.
        return reconcileHibernation(&state)
      }
    }
    .forEach(\.layouts, action: \.layouts) {
      LayoutFeature()
    }
  }
}

// MARK: - Hibernation.

extension TerminalsFeature {
  /// Whether a tab is hidden: everything except the selected tab of a pane
  /// that shows content somewhere.
  private static func isTabHidden(_ tab: TabItem, pane: Pane, paneShowsContent: Bool) -> Bool {
    !(paneShowsContent && pane.selectedTabID == tab.id)
  }

  /// Whether a pane's area renders: the selected worktree's visible panes
  /// (zoom hides the rest), or any windowed pane, whose window stays open
  /// even when miniaturized.
  private static func paneShowsContent(
    _ pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    selectedWorktreeID: Worktree.ID?
  ) -> Bool {
    if layout.windowedPaneIDs.contains(pane.id) {
      return true
    }
    return layout.id == selectedWorktreeID && visiblePanes.contains(pane.id)
  }

  /// Whether recency alone keeps this hidden tab live: it is what the worktree
  /// would show if selected, and the worktree is still inside the recency
  /// window. Nothing else in a deselected worktree is worth the memory.
  private static func recencyRetains(
    _ tab: TabItem,
    pane: Pane,
    in layout: LayoutFeature.State,
    visiblePanes: Set<PaneID>,
    recentWorktreeIDs: [Worktree.ID]
  ) -> Bool {
    guard pane.selectedTabID == tab.id, visiblePanes.contains(pane.id) else { return false }
    return recentWorktreeIDs.contains(layout.id)
  }

  /// Moves a selection to the front of the candidate list. Deselecting keeps
  /// the list, so the worktree just left
  /// stays the most recent.
  private static func recordSelection(_ worktreeID: Worktree.ID?, in recents: inout [Worktree.ID]) {
    guard let worktreeID else { return }
    recents.removeAll { $0 == worktreeID }
    recents.insert(worktreeID, at: 0)
  }

  /// Reconciles affected layouts plus retention changes. Initial selection and
  /// global policy/hydration changes still establish a complete baseline.
  private func reconcileHibernation(
    _ state: inout State,
    affectedWorktrees: Set<Worktree.ID>? = nil,
    previousTabs: Set<TabID> = [],
    onlyTab: TabID? = nil,
    pendingHibernation: Set<TabID> = [],
    pendingWakeCancellation: Set<TabID> = []
  ) -> Effect<Action> {
    let previousRetained = Set(state.recentWorktreeIDs)
    let candidates = state.recentWorktreeIDs.map { id in
      ContentRetentionPolicy.Candidate(id: id, estimatedBytes: retentionBytes(for: id, in: state))
    }
    state.recentWorktreeIDs = retentionPolicy.retained(
      candidates, selected: state.selectedWorktreeID)
    let retentionChanged = previousRetained.symmetricDifference(state.recentWorktreeIDs)
    let affected =
      state.selectedWorktreeID == nil && onlyTab == nil
      ? nil
      : affectedWorktrees.map {
        $0.union(retentionChanged)
      }
    let layouts =
      affected.map { ids in
        ids.sorted { $0.rawValue < $1.rawValue }.compactMap { state.layouts[id: $0] }
      } ?? Array(state.layouts)
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let enabled = settingsFile.global.terminalHibernationEnabled
    var hidden: Set<TabID> = []
    var retained: Set<TabID> = []
    var allTabs: Set<TabID> = []
    var effects: [Effect<Action>] = []
    for layout in layouts {
      // A hibernate completion changes one renderer, not its siblings'
      // visibility. In a pressure batch those siblings may still be queued
      // for release; revisiting them would create redundant grace timers.
      let limitsToTab =
        onlyTab != nil && affected != nil
        && affectedWorktrees?.contains(layout.id) == true && !retentionChanged.contains(layout.id)
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedWorktreeID: state.selectedWorktreeID
        )
        for tab in pane.tabs where !limitsToTab || tab.id == onlyTab {
          allTabs.insert(tab.id)
          let isHidden = Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent)
          if isHidden {
            hidden.insert(tab.id)
            state.wakeRequestedTabs.remove(tab.id)
            // Pressure already queued these renderers for release; do not
            // arm another timer while their hibernate actions are in flight.
            if pendingHibernation.contains(tab.id) { continue }
            guard
              !Self.recencyRetains(
                tab,
                pane: pane,
                in: layout,
                visiblePanes: visiblePanes,
                recentWorktreeIDs: state.recentWorktreeIDs
              )
            else {
              retained.insert(tab.id)
              continue
            }
            // A wake still deferring for a tab that just went hidden would
            // spawn a surface nobody shows and nothing recency-retains; drop it
            // before the spawn lands. Scrubbing through N hibernated worktrees
            // then costs N-1 cancellations instead of N-1 full spawns.
            if layout.wakingTabs.contains(tab.id), !pendingWakeCancellation.contains(tab.id) {
              effects.append(.send(.layouts(.element(id: layout.id, action: .cancelWake(id: tab.id)))))
            }
            guard enabled, !state.hibernationArmedTabs.contains(tab.id) else { continue }
            // Arm only live renderers; hibernated tabs have nothing to tear
            // down and re-arm on wake through this same funnel.
            guard contentRuntime.content(for: tab.content.id)?.renderer != nil else { continue }
            state.hibernationArmedTabs.insert(tab.id)
            effects.append(armGraceTimer(worktreeID: layout.id, tabID: tab.id))
          } else if contentNeedsWake(tab) {
            // The selection landed on a hibernated tab; wake it at its frozen
            // geometry, once per visibility spell so a failed wake can't loop.
            guard !state.wakeRequestedTabs.contains(tab.id) else { continue }
            state.wakeRequestedTabs.insert(tab.id)
            effects.append(.send(.layouts(.element(id: layout.id, action: .wakeTab(id: tab.id)))))
          } else {
            state.wakeRequestedTabs.remove(tab.id)
          }
        }
      }
    }
    // Cancel timers for tabs that became visible, vanished, gained recency
    // cover, or lost the flag.
    let examinedTabs = allTabs.union(previousTabs)
    for armed in state.hibernationArmedTabs
    where !enabled
      || ((affected == nil || examinedTabs.contains(armed))
        && (!hidden.contains(armed) || retained.contains(armed)))
    {
      state.hibernationArmedTabs.remove(armed)
      state.hibernationDeferralLogged.remove(armed)
      effects.append(.cancel(id: HibernationTimerID.tab(armed)))
    }
    if affected == nil {
      state.wakeRequestedTabs.formIntersection(allTabs)
      state.hibernationDeferralLogged.formIntersection(allTabs)
    } else {
      let removed = previousTabs.subtracting(allTabs)
      state.wakeRequestedTabs.subtract(removed)
      state.hibernationDeferralLogged.subtract(removed)
    }
    return effects.isEmpty ? .none : .merge(effects)
  }

  private func retentionBytes(for worktreeID: Worktree.ID, in state: State) -> UInt64 {
    guard let layout = state.layouts[id: worktreeID] else {
      return ContentRetentionPolicy.unknownContentBytes
    }
    var bytes: UInt64 = 0
    for paneID in layout.layout.tree.visibleLeaves() {
      guard let tab = layout.layout.panes[id: paneID]?.selectedTab else { continue }
      let cost =
        contentRuntime.content(for: tab.content.id)?.estimatedRetentionBytes
        ?? ContentRetentionPolicy.unknownContentBytes
      let (total, overflow) = bytes.addingReportingOverflow(cost)
      if overflow { return .max }
      bytes = total
    }
    return bytes == 0 ? ContentRetentionPolicy.unknownContentBytes : bytes
  }

  /// True when a visible tab's content has no live renderer to show.
  private func contentNeedsWake(_ tab: TabItem) -> Bool {
    guard let content = contentRuntime.content(for: tab.content.id) else { return true }
    return content.renderer == nil
  }

  private func armGraceTimer(worktreeID: Worktree.ID, tabID: TabID) -> Effect<Action> {
    let clock = clock
    // Register cancellation synchronously with the subscription. An async
    // run effect can register after a rapid selection already cancelled it,
    // leaving a hidden timer alive until its deadline.
    return .publisher {
      Deferred {
        let subject = PassthroughSubject<Action, Never>()
        let timerTask = Task { @MainActor in
          defer { subject.send(completion: .finished) }
          do {
            try await clock.sleep(for: Self.hibernationGraceWindow)
            try Task.checkCancellation()
            subject.send(.hibernationGraceElapsed(worktreeID: worktreeID, tabID: tabID))
          } catch is CancellationError {
            // Selection, closure, policy changes, and pressure cancel timers.
          } catch {
            Self.logger.error("Hibernation timer failed: \(error)")
          }
        }
        return subject.handleEvents(receiveCancel: { timerTask.cancel() })
      }
    }
    .cancellable(id: HibernationTimerID.tab(tabID), cancelInFlight: true)
  }

  /// One synchronous turn: re-check hidden and eligible, then hibernate or
  /// re-arm, so a concurrent selection cannot slip a visible tab into
  /// hibernation.
  private func reduceHibernationGraceElapsed(
    _ state: inout State,
    worktreeID: Worktree.ID,
    tabID: TabID
  ) -> Effect<Action> {
    state.hibernationArmedTabs.remove(tabID)
    @Shared(.settingsFile) var settingsFile: SettingsFile
    // Re-check at fire time so a flip to off mid-window never hibernates.
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    guard let layout = state.layouts[id: worktreeID],
      let pane = layout.layout.pane(containingTab: tabID),
      let tab = pane.tabs[id: tabID]
    else { return .none }
    let visiblePanes = Set(layout.layout.tree.visibleLeaves())
    guard
      Self.isTabHidden(
        tab,
        pane: pane,
        paneShowsContent: Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedWorktreeID: state.selectedWorktreeID
        )
      ),
      // Recency can cover a tab after its timer armed; the fire-time gate has
      // to agree with the arm-time one or a protected tab still hibernates.
      !Self.recencyRetains(
        tab,
        pane: pane,
        in: layout,
        visiblePanes: visiblePanes,
        recentWorktreeIDs: state.recentWorktreeIDs
      )
    else { return .none }
    guard layout.alert == nil else {
      // A pending close confirmation must keep its target live; re-arm.
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    guard contentRuntime.content(for: tab.content.id)?.isHibernatable == true else {
      // Still hidden but momentarily ineligible; re-arm so a later
      // eligibility flip still hibernates instead of wedging forever.
      if state.hibernationDeferralLogged.insert(tabID).inserted {
        Self.logger.debug("Hibernation for tab \(tabID.rawValue) deferred: not currently eligible; re-armed.")
      }
      state.hibernationArmedTabs.insert(tabID)
      return armGraceTimer(worktreeID: worktreeID, tabID: tabID)
    }
    state.hibernationDeferralLogged.remove(tabID)
    return .send(.layouts(.element(id: worktreeID, action: .hibernateTab(id: tabID))))
  }

  /// Under pressure the recency budget is the first thing to go: keep the
  /// selection, hibernate everything hidden right now instead of waiting out
  /// the grace window. The Beta flag still gates it — a user who turned
  /// hibernation off never gets a surface dropped behind their back.
  private func reduceMemoryPressureWarning(_ state: inout State) -> Effect<Action> {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    guard settingsFile.global.terminalHibernationEnabled else { return .none }
    state.recentWorktreeIDs = state.selectedWorktreeID.map { [$0] } ?? []
    var effects: [Effect<Action>] = []
    var wakeCancellations: [Effect<Action>] = []
    var pendingWakeCancellation: Set<TabID> = []
    var pendingHibernation: Set<TabID> = []
    for layout in state.layouts {
      let visiblePanes = Set(layout.layout.tree.visibleLeaves())
      for pane in layout.layout.panes {
        let showsContent = Self.paneShowsContent(
          pane,
          in: layout,
          visiblePanes: visiblePanes,
          selectedWorktreeID: state.selectedWorktreeID
        )
        for tab in pane.tabs
        where Self.isTabHidden(tab, pane: pane, paneShowsContent: showsContent) {
          if layout.wakingTabs.contains(tab.id) {
            pendingWakeCancellation.insert(tab.id)
            wakeCancellations.append(.send(.layouts(.element(id: layout.id, action: .cancelWake(id: tab.id)))))
          }
          guard contentRuntime.content(for: tab.content.id)?.isHibernatable == true else { continue }
          // Disarm first: a timer left over a hibernated tab would fire into
          // the ineligible re-arm branch and never settle.
          if state.hibernationArmedTabs.remove(tab.id) != nil {
            state.hibernationDeferralLogged.remove(tab.id)
            effects.append(.cancel(id: HibernationTimerID.tab(tab.id)))
          }
          pendingHibernation.insert(tab.id)
          effects.append(.send(.layouts(.element(id: layout.id, action: .hibernateTab(id: tab.id)))))
        }
      }
    }
    // Pressure changes retention globally. Local hibernate completions cannot
    // re-arm newly uncovered, temporarily ineligible content in other layouts.
    let reconciliation = reconcileHibernation(
      &state, pendingHibernation: pendingHibernation,
      pendingWakeCancellation: pendingWakeCancellation)
    if !pendingHibernation.isEmpty {
      Self.logger.info("Memory pressure: hibernating \(pendingHibernation.count) hidden tabs.")
    }
    // Cancel hidden pending wakes before hibernate completions inspect their
    // layout, so those completions cannot enqueue the same cancellation.
    // Only immediate cancellation actions precede the release. Grace timers
    // for ineligible content must run alongside it, never delay it.
    return .concatenate(.merge(wakeCancellations), .merge(reconciliation, .merge(effects)))
  }
}
