import SupacodeSettingsShared
import SwiftUI

enum PullRequestBadgeStyle {
  // The same three states the sidebar's leading icon paints, so they take the
  // same damped hues; the pill is an outline plus text in this colour, which at
  // full chroma made it the loudest thing in the row.
  static let mergedColor = Color.pullRequestMerged
  static let openColor = Color.pullRequestOpen
  static let queuedColor = Color.pullRequestQueued

  static func style(state: String?, number: Int?, isQueued: Bool = false) -> (text: String, color: Color)? {
    guard let state = state?.uppercased() else {
      return nil
    }
    switch state {
    case "MERGED":
      return (text: number.map { "#\($0)" } ?? "MERGED", color: mergedColor)
    case "OPEN":
      return (text: number.map { "#\($0)" } ?? "OPEN", color: isQueued ? queuedColor : openColor)
    default:
      return nil
    }
  }

  static func helpText(state: String?, url: URL?) -> String {
    let state = state?.uppercased()
    switch state {
    case "MERGED":
      return url == nil ? "Pull request merged" : "Open merged pull request on GitHub"
    case "OPEN":
      return url == nil ? "Pull request open" : "Open pull request on GitHub"
    default:
      return url == nil ? "Pull request" : "Open pull request on GitHub"
    }
  }
}

struct PullRequestBadgeView: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text)
      .appFont(.caption2)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .fixedSize(horizontal: true, vertical: false)
      .overlay {
        RoundedRectangle(cornerRadius: 4)
          .stroke(color, lineWidth: 1)
      }
      .accessibilityLabel(text)
  }
}
