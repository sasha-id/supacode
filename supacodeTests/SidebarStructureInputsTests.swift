import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Coverage for the input-signature gate in front of
/// `recomputeSidebarStructureIfChanged()`. Each case blanks the cached
/// structure first: only a rerun of the walk can put it back, so the cached
/// value after the call says whether the gate let the walk run.
@MainActor
struct SidebarStructureInputsTests {
  private static let repoRoot = URL(fileURLWithPath: "/tmp/inputs-repo")
  private static let worktreeID = WorktreeID("/tmp/inputs-repo/wt-feature")

  private func makeState() -> RepositoriesFeature.State {
    let main = Worktree(
      id: WorktreeID(Self.repoRoot.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: Self.repoRoot,
      repositoryRootURL: Self.repoRoot
    )
    let feature = Worktree(
      id: Self.worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: Self.worktreeID.rawValue),
      repositoryRootURL: Self.repoRoot
    )
    let repository = Repository(
      id: RepositoryID(Self.repoRoot.path(percentEncoded: false)),
      rootURL: Self.repoRoot,
      name: "inputs-repo",
      worktrees: IdentifiedArray(uniqueElements: [main, feature])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.isInitialLoadComplete = true
    state.recomputeSidebarStructureIfChanged()
    return state
  }

  @Test func unchangedInputsSkipTheWalk() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      var state = makeState()
      #expect(state.sidebarStructure != .empty)

      state.sidebarStructure = .empty
      state.recomputeSidebarStructureIfChanged()

      #expect(state.sidebarStructure == .empty)
    }
  }

  @Test func aLeafTickTheWalkNeverReadsSkipsIt() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      var state = makeState()
      state.sidebarItems[id: Self.worktreeID]?.agentSnapshot.agents = [
        .init(agent: .claude, activity: .busy)
      ]
      state.recomputeSidebarStructureIfChanged()

      // A second badge leaves the row's Active classification at `.agent`, and
      // the walk reads nothing else off the snapshot.
      state.sidebarStructure = .empty
      state.sidebarItems[id: Self.worktreeID]?.agentSnapshot.agents.append(
        .init(agent: .codex, activity: .busy)
      )
      state.sidebarItems[id: Self.worktreeID]?.agentSnapshot.isWorking = true
      state.recomputeSidebarStructureIfChanged()

      #expect(state.sidebarStructure == .empty)
    }
  }

  @Test func aRowFieldTheWalkRendersRunsIt() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      var state = makeState()

      state.sidebarStructure = .empty
      state.sidebarItems[id: Self.worktreeID]?.customTitle = "renamed"
      state.recomputeSidebarStructureIfChanged()

      #expect(state.sidebarStructure != .empty)
      #expect(state.sidebarStructure.hotkeySlots.contains { $0.name == "renamed" })
    }
  }

  @Test func aClassificationFlipRunsIt() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      var state = makeState()

      state.sidebarStructure = .empty
      state.sidebarItems[id: Self.worktreeID]?.hasUnseenNotifications = true
      state.recomputeSidebarStructureIfChanged()

      #expect(state.sidebarStructure != .empty)
    }
  }

  @Test func aSharedToggleFlipRunsIt() {
    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      var state = makeState()

      state.sidebarStructure = .empty
      @Shared(.sidebarSectionSort) var sectionSort
      $sectionSort.withLock { $0 = $0 == .alphabetical ? .manual : .alphabetical }
      state.recomputeSidebarStructureIfChanged()

      #expect(state.sidebarStructure != .empty)
    }
  }
}
