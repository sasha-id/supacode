import AppKit
import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

/// Locks the switch contract: a worktree's mounted tree survives deselection,
/// so no live Ghostty surface is ever reparented by a selection change.
@MainActor
struct WorktreeTerminalStackViewTests {
  /// The shared references a stack's inputs carry, minted once per test so
  /// only the worktree distinguishes two input values.
  @MainActor
  private struct Fixture {
    let stack = WorktreeTerminalStackView()
    let contentRuntime = ContentRuntime()
    let commandKeys = CommandKeyObserver()
    let manager: WorktreeTerminalManager
    let terminalsStore: StoreOf<TerminalsFeature>
    let shortcuts: GhosttyShortcutManager

    init() {
      let runtime = GhosttyRuntime()
      manager = WorktreeTerminalManager(runtime: runtime)
      terminalsStore = Store(initialState: TerminalsFeature.State()) { TerminalsFeature() }
      shortcuts = GhosttyShortcutManager(runtime: runtime)
    }

    func inputs(_ id: String) -> WorktreeTerminalInputs {
      WorktreeTerminalInputs(
        worktree: Worktree(
          id: WorktreeID(id),
          name: URL(fileURLWithPath: id).lastPathComponent,
          detail: "detail",
          workingDirectory: URL(fileURLWithPath: id),
          repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
        ),
        manager: manager,
        terminalsStore: terminalsStore,
        runtime: contentRuntime,
        ghosttyShortcuts: shortcuts,
        commandKeyObserver: commandKeys
      )
    }
  }

  @Test func reselectingTheSameWorktreeLeavesTheHostedRootAlone() {
    let fixture = Fixture()
    let inputs = fixture.inputs("/tmp/repo/wt-a")

    fixture.stack.select(inputs)
    #expect(fixture.stack.hostedRootWrites == 1)

    fixture.stack.select(inputs)
    #expect(fixture.stack.hostedRootWrites == 1)
    #expect(fixture.stack.mountedWorktreeIDs == [inputs.worktree.id])
  }

  @Test func switchingKeepsTheOutgoingTreeMountedAndHidden() {
    let fixture = Fixture()
    let first = fixture.inputs("/tmp/repo/wt-a")
    let second = fixture.inputs("/tmp/repo/wt-b")

    fixture.stack.select(first)
    let firstHost = fixture.stack.hostedView(for: first.worktree.id)
    fixture.stack.select(second)

    #expect(fixture.stack.selectedWorktreeID == second.worktree.id)
    // Same view object, still in the hierarchy: nothing it hosts was detached,
    // so nothing under it was reparented.
    #expect(fixture.stack.hostedView(for: first.worktree.id) === firstHost)
    #expect(firstHost?.superview === fixture.stack)
    #expect(firstHost?.isHidden == true)
    #expect(fixture.stack.hostedView(for: second.worktree.id)?.isHidden == false)
  }

  @Test func switchingBackReusesTheMountedTree() {
    let fixture = Fixture()
    let first = fixture.inputs("/tmp/repo/wt-a")
    let second = fixture.inputs("/tmp/repo/wt-b")

    fixture.stack.select(first)
    let firstHost = fixture.stack.hostedView(for: first.worktree.id)
    fixture.stack.select(second)
    fixture.stack.select(first)

    #expect(fixture.stack.hostedView(for: first.worktree.id) === firstHost)
    #expect(firstHost?.isHidden == false)
    #expect(fixture.stack.hostedView(for: second.worktree.id)?.isHidden == true)
    #expect(fixture.stack.mountedWorktreeIDs == [second.worktree.id, first.worktree.id])
  }

  /// The keyboard can sit on a text field (find bar, tab rename), not only on a
  /// surface, so the handoff asks the whole outgoing tree — a field answers
  /// through its field editor, mounted inside it.
  @Test func aTextFieldInTheTreeCountsAsHoldingTheKeyboard() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    let tree = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
    tree.addSubview(field)
    window.contentView?.addSubview(tree)

    #expect(!WorktreeTerminalStackView.containsFirstResponder(tree))
    #expect(window.makeFirstResponder(field))
    #expect(WorktreeTerminalStackView.containsFirstResponder(tree))

    // Parking on the window is what the handoff does to free the keyboard.
    window.makeFirstResponder(nil)
    #expect(!WorktreeTerminalStackView.containsFirstResponder(tree))
  }

  /// A transient detail state (loading, multi-selection, archived list) parks
  /// the stack instead of unmounting it, so returning costs nothing.
  @Test func parkingKeepsEveryTreeMountedAndHidden() {
    let fixture = Fixture()
    let first = fixture.inputs("/tmp/repo/wt-a")
    let second = fixture.inputs("/tmp/repo/wt-b")

    fixture.stack.select(first)
    fixture.stack.select(second)
    let firstHost = fixture.stack.hostedView(for: first.worktree.id)
    let secondHost = fixture.stack.hostedView(for: second.worktree.id)

    fixture.stack.select(nil)

    #expect(fixture.stack.selectedWorktreeID == nil)
    #expect(fixture.stack.hostedView(for: first.worktree.id) === firstHost)
    #expect(fixture.stack.hostedView(for: second.worktree.id) === secondHost)
    #expect(firstHost?.superview === fixture.stack)
    #expect(secondHost?.superview === fixture.stack)
    #expect(firstHost?.isHidden == true)
    #expect(secondHost?.isHidden == true)

    fixture.stack.select(second)
    #expect(fixture.stack.hostedView(for: second.worktree.id) === secondHost)
    #expect(secondHost?.isHidden == false)
    #expect(fixture.stack.mountedWorktreeIDs == [first.worktree.id, second.worktree.id])
  }

  @Test func mountingPastTheLimitEvictsTheLeastRecentlySelected() {
    let fixture = Fixture()
    let visited = (0...WorktreeTerminalStackView.mountLimit).map { fixture.inputs("/tmp/repo/wt-\($0)") }

    for inputs in visited {
      fixture.stack.select(inputs)
    }

    #expect(fixture.stack.mountedWorktreeIDs.count == WorktreeTerminalStackView.mountLimit)
    #expect(fixture.stack.hostedView(for: visited[0].worktree.id) == nil)
    #expect(fixture.stack.selectedWorktreeID == visited[visited.count - 1].worktree.id)
  }
}
