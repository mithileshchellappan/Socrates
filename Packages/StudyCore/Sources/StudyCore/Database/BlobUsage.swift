import Foundation
import SQLiteData

/// Whether a content-addressed file is still used by a row: the one check before any code removes
/// a file from the BlobStore (Filing's deletes and Undo, md: the document bank's deletes), so no
/// remover forgets a table. A table that gains a blob column adds itself here.
public enum BlobUsage {
    /// True when a row refers to the file with this hash: a deck, a recording segment, a mail
    /// attachment, a reading, a question's source, a kept document (v14), a note's image or sketch
    /// (`note.blocks` JSON) or a chat attachment (`agent_turn.context` JSON). An empty hash counts
    /// as used (a file nobody can name is never removed).
    public static func isUsed(_ sha256: String, in db: Database) throws -> Bool {
        guard !sha256.isEmpty else { return true }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM "deck" WHERE "blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "recording_segment" WHERE "blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "mail_attachment" WHERE "blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "study_reading" WHERE "blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "study_question" WHERE "source_blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "document" WHERE "blob_sha256" = ?1)
                OR EXISTS (SELECT 1 FROM "note" WHERE "blocks" LIKE ?2)
                OR EXISTS (SELECT 1 FROM "agent_turn" WHERE "context" LIKE ?2)
            """, arguments: [sha256, "%" + sha256 + "%"]) ?? true
    }
}
