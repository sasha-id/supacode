import SwiftUI

struct PullRequestCheckStatusStyle {
  let symbol: String
  let color: Color
  let label: String

  init(state: GithubPullRequestCheckState) {
    switch state {
    case .success:
      self.symbol = "checkmark.circle.fill"
      self.color = .checkSuccess
      self.label = "Success"
    case .failure:
      self.symbol = "xmark.circle.fill"
      self.color = .red
      self.label = "Failed"
    case .inProgress:
      self.symbol = "arrow.triangle.2.circlepath.circle.fill"
      self.color = .yellow
      self.label = "In progress"
    case .expected:
      self.symbol = "clock.circle.fill"
      self.color = .yellow
      self.label = "Expected"
    case .skipped:
      self.symbol = "minus.circle.fill"
      self.color = .gray
      self.label = "Skipped"
    }
  }
}

extension ShapeStyle where Self == Color {
  /// CI success. Plain `.green` is the brightest thing on a sidebar row by a
  /// wide margin, so it's pulled a third of the way toward gray: still
  /// unmistakably a pass, no longer a signal flare next to muted row text.
  static var checkSuccess: Color { Color.green.mix(with: .gray, by: 0.35) }
}
