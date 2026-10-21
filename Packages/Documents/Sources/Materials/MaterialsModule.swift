import Foundation
import os
import StudyCore

/// Course materials (mt, docs/plan-materials.md "Build plan", workstream A): `MaterialLibrary`
/// (an actor implementing `MaterialLibraryActions`: add files, links, attachments and wanted
/// books; read through the bank with role `material`; sections, printed pages, covers; delete
/// with Undo; Read Again; Refresh), `MaterialClassifier` (book / paper / slides, code only),
/// `SectionReader`, `LinkFetcher` (`PublicFetch`), `MaterialCard` and `ChapterSummarizer` (the
/// Haiku calls the agent's task queue runs). No SwiftUI. Logs through `Log.materials`; never
/// logs a material's text or title at `.public`.
public enum MaterialsModule {
    public static let moduleName = "Materials"
}
