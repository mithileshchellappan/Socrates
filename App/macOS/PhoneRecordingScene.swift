import LinkUI
import SwiftUI

/// link (DESIGN 8.11, mockups 62a–b): the iPhone's recording in the menu bar, from its first
/// snapshot until it is filed here and while a recording arrives (`PhoneLink.showsItem`); a
/// window with the recording, its controls and the arrivals. Only in a build that syncs (no
/// `phoneLink` otherwise) and only while Socrates runs.
struct PhoneRecordingScene: Scene {
    let model: AppModel

    var body: some Scene {
        // Read in the body, so the scene follows the link through observation: the item is
        // inserted and removed with it, whether or not SwiftUI tracks a binding's getter.
        let showsItem = model.phoneLink?.showsItem ?? false
        MenuBarExtra(isInserted: .constant(showsItem)) {
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
}
