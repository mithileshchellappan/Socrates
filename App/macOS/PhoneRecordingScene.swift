import LinkUI
import SwiftUI

/// link (DESIGN 8.11, mockups 62a–b): the iPhone's recording in the menu bar, from its first
/// snapshot until it is filed here and while a recording arrives (`PhoneLink.showsItem`); a
/// window with the recording, its controls and the arrivals. Only in a build that syncs (no
/// `phoneLink` otherwise) and only while Socrates runs.
struct PhoneRecordingScene: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra(isInserted: isInserted) {
            if let link = model.phoneLink {
                PhoneRecordingPanel(link: link)
            }
        } label: {
            if let link = model.phoneLink {
                PhoneRecordingMenuLabel(link: link)
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// The link alone decides whether the item shows.
    private var isInserted: Binding<Bool> {
        Binding(get: { model.phoneLink?.showsItem ?? false }, set: { _ in })
    }
}
