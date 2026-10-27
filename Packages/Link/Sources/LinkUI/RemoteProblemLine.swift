import Link
import SwiftUI

/// A remote command the phone could not do, in red 12 under the controls: the title semibold,
/// then the recorder's sentence where it has one. The link clears it on the next action.
struct RemoteProblemLine: View {
    let problem: RemoteProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(problem.title)
                .fontWeight(.semibold)
            if let message = problem.message {
                Text(message)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
