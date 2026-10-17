import Filing
import SwiftUI

/// File ▸ Import… (⇧⌘I): picks slides, recordings or captured lectures and files them like a
/// drop. The panel is presented by the window that has `.smartImport(center)`.
public struct ImportCommands: Commands {
    let center: FilingCenter

    public init(center: FilingCenter) {
        self.center = center
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") { center.importFiles() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
