import Foundation
import StudyCore
import SwiftUI

/// What the Documents screen may do to the bank (docs/plan-docs.md §3, §6): the app's closures over
/// `DocumentBank` (Mac). The screen reads rows itself and writes only through these. The inert
/// default (previews, the iPhone) is read-only.
public struct DocumentActions: Sendable {
    /// Import…, drop, Delete and Read Again exist (the Mac); false: read-only (the iPhone).
    public var isEditable: Bool
    /// Adds files (a drop, Import…); returns their documents in order (an already kept file's own).
    public var add: @Sendable ([URL]) async throws -> [StudyDocument.ID]
    /// Deletes a document; what Undo needs (nil: it was gone).
    public var delete: @Sendable (StudyDocument.ID) async throws -> DocumentDeletion?
    /// Undo of `delete`.
    public var restore: @Sendable (DocumentDeletion) async throws -> Void
    /// Read Again after a failure.
    public var retry: @Sendable (StudyDocument.ID) async -> Void

    public init(
        isEditable: Bool,
        add: @escaping @Sendable ([URL]) async throws -> [StudyDocument.ID],
        delete: @escaping @Sendable (StudyDocument.ID) async throws -> DocumentDeletion?,
        restore: @escaping @Sendable (DocumentDeletion) async throws -> Void,
        retry: @escaping @Sendable (StudyDocument.ID) async -> Void
    ) {
        self.isEditable = isEditable
        self.add = add
        self.delete = delete
        self.restore = restore
        self.retry = retry
    }

    /// Read-only: nothing is added, deleted or read again.
    public static let readOnly = DocumentActions(
        isEditable: false, add: { _ in [] }, delete: { _ in nil }, restore: { _ in }, retry: { _ in }
    )
}

extension EnvironmentValues {
    /// The Documents screen's writes (read-only by default).
    @Entry public var documentActions: DocumentActions = .readOnly
}
