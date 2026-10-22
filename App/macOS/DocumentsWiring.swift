import Documents
import DocumentsUI
import FilingUI
import MaterialsUI
import StudyCore
import SwiftUI

// md (docs/plan-docs.md §7.2): the app's wiring of the document bank (Mac only: documents never
// sync, the iPhone has no Documents screen).

extension AppModel {
    /// What the Documents screen may do (`\.documentActions`): the bank's add, delete, restore and
    /// retry; read-only without a library.
    var documentActions: DocumentActions {
        guard let bank = documentBank else { return .readOnly }
        return DocumentActions(
            isEditable: true,
            // Every file's document, an already kept one's too (the screen selects the first).
            add: { urls in try await bank.add(urls, by: .user).map(\.document.id) },
            delete: { id in try await bank.delete(id) },
            restore: { deletion in try await bank.restore(deletion) },
            retry: { id in await bank.retry(id) }
        )
    }
}

/// File ▸ Import… (⇧⌘I): the Documents importer while Documents shows (`\.documentsImport`),
/// the course's materials importer while its Materials shows (mt, `\.materialsImport`), smart
/// import's panel everywhere else. Replaces FilingUI's `ImportCommands` on the Mac.
struct AppImportCommands: Commands {
    let center: FilingCenter
    @FocusedValue(\.documentsImport) private var documentsImport
    @FocusedValue(\.materialsImport) private var materialsImport

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import…") {
                if let documentsImport {
                    documentsImport()
                } else if let materialsImport {
                    materialsImport()
                } else {
                    center.importFiles()
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}
