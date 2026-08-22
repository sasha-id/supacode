import SupacodeSettingsShared
import SwiftUI

enum PullRequestBadgeStyle {
  // The same three states the sidebar's leading icon paints, so they take the
  // same damped hues; the pill is an outline plus text in this colour, which at
  // full chroma made it the loudest thing in the row.
  static let mergedColor = Color.pullRequestMerged
  static let openColor = Color.pullRequestOpen
  static let queuedColor = Color.pullRequestQueued

  static func style(
    state: PullRequestState?,
    number: Int?,
    isQueued: Bool = false,
    numberSigil: String = "#"
  ) -> (text: String, color: Color)? {
    switch state {
    case .merged:
      return (text: number.map { "\(numberSigil)\($0)" } ?? "MERGED", color: mergedColor)
    case .open:
      return (text: number.map { "\(numberSigil)\($0)" } ?? "OPEN", color: isQueued ? queuedColor : openColor)
    case .closed, .unknown, .none:
      return nil
    }
  }

  static func helpText(state: PullRequestState?, url: URL?) -> String {
    switch state {
    case .merged:
      return url == nil ? "Pull request merged" : "Open merged pull request on GitHub"
    case .open:
      return url == nil ? "Pull request open" : "Open pull request on GitHub"
    case .closed, .unknown, .none:
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
