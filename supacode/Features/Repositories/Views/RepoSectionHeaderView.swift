import SupacodeSettingsShared
import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let customTitle: String?
  /// Muted `(N)` worktree count next to the title; `nil` hides it (failed /
  /// blocked repos render no rows to count).
  var worktreeCount: Int?
  let isRemoving: Bool
  /// `[user@]host[:port]` when the repository lives on an SSH host, else nil;
  /// surfaces a `wifi` glyph beside the title, full value shown on hover.
  var hostInfo: String?
  /// Remote repository whose SSH listing is still resolving; shows a spinner.
  var isResolving: Bool = false

  private var displayName: String {
    Repository.sidebarDisplayName(custom: customTitle, fallback: name)
  }

  var body: some View {
    HStack(spacing: 4) {
      // The repository name is the sidebar's primary label, so it has to follow
      // the text scale like the rows beneath it. The repo color no longer tints
      // the title — it lives on the leading accent stripe instead.
      Text(displayName)
        .appFontInheriting(.subheadline, weight: .semibold)
      if let worktreeCount {
        Text("(\(worktreeCount))")
          .appFontInheriting(.subheadline)
          .foregroundStyle(.secondary)
      }
      if let hostInfo {
        Image(systemName: "wifi")
          .imageScale(.small)
          .appFontInheriting(.subheadline)
          .foregroundStyle(.secondary)
          .help(hostInfo)
          .accessibilityLabel("Remote host \(hostInfo)")
      }
      if isRemoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Removing repository")
      } else if isResolving {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("Connecting to remote")
      }
    }
  }
}
