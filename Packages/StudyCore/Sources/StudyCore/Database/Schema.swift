import Foundation
import SQLiteData

/// Schema migrations. Append new migrations; never edit a shipped one.
///
/// CloudKit-friendly rules (SQLiteData SyncEngine, docs/schema.md):
/// UUID TEXT primary keys, no UNIQUE constraints/indexes besides the primary key,
/// `ON DELETE` only CASCADE / SET NULL, columns added later must be nullable or have
/// `NOT NULL ON CONFLICT REPLACE DEFAULT …`, no CloudKit-reserved column names.
public enum Schema {
    public static let migrationIDs = ["v1", "v2", "v3", "v4"]

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        // Foreign key checks are deferred (GRDB's default), so the table rebuild cannot cascade.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: v3)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: v4)
        }
        return migrator
    }

    /// Every library table created by the migrations, in creation order: UUID keys, synced in M7.
    public static let tableNames = [
        "course", "weekly_slot", "lecture_session", "deck", "deck_page", "lecture", "recording",
        "lecture_deck_span", "recording_segment", "slide_event", "transcript_segment", "api_call",
        "note", "annotation", "tracked_item", "job",
        "semester", "filing",
    ]

    /// Derived, device-local tables (rebuilt from the library, never synced): the search index.
    /// `search_chunk` has an INTEGER key (the FTS5 content rowid).
    public static let localTableNames = ["search_chunk"]

    /// FTS5 virtual tables over `search_chunk` (their shadow tables are named `<name>_…`).
    public static let virtualTableNames = ["search_fts", "search_trigram"]

    static let v1 = """
        CREATE TABLE "course" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "short_name" TEXT NOT NULL DEFAULT '',
          "professors" TEXT NOT NULL DEFAULT '[]',
          "language" TEXT NOT NULL DEFAULT 'en',
          "admin_language" TEXT NOT NULL DEFAULT 'de',
          "color_hex" TEXT NOT NULL DEFAULT '#0a84ff',
          "glossary" TEXT NOT NULL DEFAULT '',
          "exercise_rules" TEXT NOT NULL DEFAULT '',
          "exam_rules" TEXT NOT NULL DEFAULT '',
          "recording_consent_at" TEXT,
          "mail_rules" TEXT NOT NULL DEFAULT '[]',
          "sort_order" INTEGER NOT NULL DEFAULT 0,
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;

        CREATE TABLE "weekly_slot" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT NOT NULL REFERENCES "course"("id") ON DELETE CASCADE,
          "kind" TEXT NOT NULL DEFAULT 'lecture',
          "weekday" INTEGER NOT NULL DEFAULT 1,
          "start_minute" INTEGER NOT NULL DEFAULT 0,
          "duration_minutes" INTEGER NOT NULL DEFAULT 90,
          "room" TEXT NOT NULL DEFAULT '',
          "time_zone" TEXT NOT NULL DEFAULT '',
          "valid_from" TEXT,
          "valid_until" TEXT,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "weekly_slot_course" ON "weekly_slot"("course_id");

        CREATE TABLE "lecture_session" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT NOT NULL REFERENCES "course"("id") ON DELETE CASCADE,
          "weekly_slot_id" TEXT REFERENCES "weekly_slot"("id") ON DELETE SET NULL,
          "kind" TEXT NOT NULL DEFAULT 'lecture',
          "starts_at" TEXT NOT NULL,
          "ends_at" TEXT NOT NULL,
          "room" TEXT NOT NULL DEFAULT '',
          "is_cancelled" INTEGER NOT NULL DEFAULT 0,
          "calendar_event_id" TEXT,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "lecture_session_course_start" ON "lecture_session"("course_id", "starts_at");
        CREATE INDEX "lecture_session_start" ON "lecture_session"("starts_at");

        CREATE TABLE "deck" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT REFERENCES "course"("id") ON DELETE SET NULL,
          "title" TEXT NOT NULL DEFAULT '',
          "file_name" TEXT NOT NULL DEFAULT '',
          "blob_sha256" TEXT NOT NULL DEFAULT '',
          "blob_path" TEXT NOT NULL DEFAULT '',
          "page_count" INTEGER NOT NULL DEFAULT 0,
          "imported_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "deck_course" ON "deck"("course_id");
        CREATE INDEX "deck_blob" ON "deck"("blob_sha256");

        CREATE TABLE "deck_page" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "deck_id" TEXT NOT NULL REFERENCES "deck"("id") ON DELETE CASCADE,
          "page_number" INTEGER NOT NULL,
          "label" TEXT NOT NULL DEFAULT '',
          "text" TEXT NOT NULL DEFAULT '',
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "deck_page_deck_page" ON "deck_page"("deck_id", "page_number");

        CREATE TABLE "lecture" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT NOT NULL REFERENCES "course"("id") ON DELETE CASCADE,
          "lecture_session_id" TEXT REFERENCES "lecture_session"("id") ON DELETE SET NULL,
          "number" INTEGER,
          "title" TEXT NOT NULL DEFAULT '',
          "held_at" TEXT,
          "language" TEXT NOT NULL DEFAULT '',
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "lecture_course_held" ON "lecture"("course_id", "held_at");
        CREATE INDEX "lecture_session_ref" ON "lecture"("lecture_session_id");

        CREATE TABLE "recording" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE SET NULL,
          "course_id" TEXT REFERENCES "course"("id") ON DELETE SET NULL,
          "source" TEXT NOT NULL DEFAULT 'mac',
          "state" TEXT NOT NULL DEFAULT 'recording',
          "started_at" TEXT NOT NULL,
          "host_time_at_start" INTEGER,
          "sample_rate" REAL NOT NULL DEFAULT 48000,
          "channel_count" INTEGER NOT NULL DEFAULT 1,
          "duration" REAL NOT NULL DEFAULT 0,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "recording_lecture" ON "recording"("lecture_id");
        CREATE INDEX "recording_course" ON "recording"("course_id");

        CREATE TABLE "lecture_deck_span" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "lecture_id" TEXT NOT NULL REFERENCES "lecture"("id") ON DELETE CASCADE,
          "deck_id" TEXT NOT NULL REFERENCES "deck"("id") ON DELETE CASCADE,
          "first_page" INTEGER NOT NULL,
          "last_page" INTEGER NOT NULL,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE SET NULL,
          "start_time" REAL,
          "end_time" REAL,
          "source" TEXT NOT NULL DEFAULT 'auto',
          "confidence" REAL NOT NULL DEFAULT 1,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "lecture_deck_span_lecture" ON "lecture_deck_span"("lecture_id", "start_time");
        CREATE INDEX "lecture_deck_span_deck" ON "lecture_deck_span"("deck_id");

        CREATE TABLE "recording_segment" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "recording_id" TEXT NOT NULL REFERENCES "recording"("id") ON DELETE CASCADE,
          "sequence" INTEGER NOT NULL DEFAULT 0,
          "start_sample" INTEGER NOT NULL DEFAULT 0,
          "frame_count" INTEGER NOT NULL DEFAULT 0,
          "blob_sha256" TEXT NOT NULL DEFAULT '',
          "blob_path" TEXT NOT NULL DEFAULT '',
          "byte_count" INTEGER NOT NULL DEFAULT 0,
          "file_format" TEXT NOT NULL DEFAULT '',
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "recording_segment_recording" ON "recording_segment"("recording_id", "sequence");

        CREATE TABLE "slide_event" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE CASCADE,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE SET NULL,
          "kind" TEXT NOT NULL DEFAULT 'show',
          "deck_id" TEXT REFERENCES "deck"("id") ON DELETE SET NULL,
          "page_number" INTEGER,
          "sample_time" INTEGER,
          "host_time" INTEGER,
          "wall_clock" TEXT NOT NULL,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "slide_event_recording" ON "slide_event"("recording_id", "sample_time");
        CREATE INDEX "slide_event_lecture" ON "slide_event"("lecture_id");

        CREATE TABLE "transcript_segment" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "recording_id" TEXT NOT NULL REFERENCES "recording"("id") ON DELETE CASCADE,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE SET NULL,
          "start_time" REAL NOT NULL,
          "end_time" REAL NOT NULL,
          "text" TEXT NOT NULL DEFAULT '',
          "original_text" TEXT NOT NULL DEFAULT '',
          "lang" TEXT NOT NULL DEFAULT '',
          "confidence" REAL,
          "revision" INTEGER NOT NULL DEFAULT 0,
          "words" TEXT,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "transcript_segment_recording" ON "transcript_segment"("recording_id", "start_time");
        CREATE INDEX "transcript_segment_lecture" ON "transcript_segment"("lecture_id", "start_time");

        CREATE TABLE "api_call" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "model" TEXT NOT NULL DEFAULT '',
          "purpose" TEXT NOT NULL DEFAULT '',
          "request_id" TEXT,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE SET NULL,
          "input_tokens" INTEGER NOT NULL DEFAULT 0,
          "output_tokens" INTEGER NOT NULL DEFAULT 0,
          "cache_read_tokens" INTEGER NOT NULL DEFAULT 0,
          "cache_write_tokens" INTEGER NOT NULL DEFAULT 0,
          "cost_usd" REAL NOT NULL DEFAULT 0,
          "duration_ms" INTEGER NOT NULL DEFAULT 0,
          "stop_reason" TEXT,
          "error" TEXT,
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "api_call_created" ON "api_call"("created_at");

        CREATE TABLE "note" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT REFERENCES "course"("id") ON DELETE SET NULL,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE CASCADE,
          "deck_id" TEXT REFERENCES "deck"("id") ON DELETE SET NULL,
          "page_number" INTEGER,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE SET NULL,
          "audio_time" REAL,
          "blocks" TEXT NOT NULL DEFAULT '[]',
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "note_lecture" ON "note"("lecture_id", "page_number");
        CREATE INDEX "note_course" ON "note"("course_id");

        CREATE TABLE "annotation" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE CASCADE,
          "layer" TEXT NOT NULL DEFAULT 'user',
          "kind" TEXT NOT NULL DEFAULT 'comment',
          "deck_id" TEXT REFERENCES "deck"("id") ON DELETE SET NULL,
          "page_number" INTEGER,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE SET NULL,
          "start_time" REAL,
          "end_time" REAL,
          "transcript_segment_id" TEXT REFERENCES "transcript_segment"("id") ON DELETE SET NULL,
          "body" TEXT NOT NULL DEFAULT '',
          "citations" TEXT NOT NULL DEFAULT '[]',
          "api_call_id" TEXT REFERENCES "api_call"("id") ON DELETE SET NULL,
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "annotation_lecture" ON "annotation"("lecture_id", "layer");
        CREATE INDEX "annotation_slide" ON "annotation"("deck_id", "page_number");

        CREATE TABLE "tracked_item" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "course_id" TEXT REFERENCES "course"("id") ON DELETE SET NULL,
          "kind" TEXT NOT NULL DEFAULT 'deadline',
          "title" TEXT NOT NULL DEFAULT '',
          "details" TEXT NOT NULL DEFAULT '',
          "due_at" TEXT,
          "is_all_day" INTEGER NOT NULL DEFAULT 0,
          "status" TEXT NOT NULL DEFAULT 'open',
          "source_quote" TEXT NOT NULL DEFAULT '',
          "source_refs" TEXT NOT NULL DEFAULT '[]',
          "calendar_event_id" TEXT,
          "created_by" TEXT NOT NULL DEFAULT 'agent',
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "tracked_item_due" ON "tracked_item"("status", "due_at");
        CREATE INDEX "tracked_item_course" ON "tracked_item"("course_id");

        CREATE TABLE "job" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "stage" TEXT NOT NULL DEFAULT '',
          "state" TEXT NOT NULL DEFAULT 'queued',
          "progress" REAL NOT NULL DEFAULT 0,
          "error" TEXT,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE CASCADE,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE CASCADE,
          "attempt" INTEGER NOT NULL DEFAULT 0,
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "started_at" TEXT,
          "finished_at" TEXT,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "job_state" ON "job"("state", "created_at");
        CREATE INDEX "job_lecture" ON "job"("lecture_id");
        CREATE INDEX "job_recording" ON "job"("recording_id");
        """

    /// v2: `lecture_deck_span.first_page` / `last_page` become nullable. A timed span with no
    /// pages is an off-slide stretch (admin talk, Q&A, breaks) from the aligner's OFF state.
    /// SQLite cannot drop NOT NULL in place, so the table is rebuilt; `recording_id` gains the
    /// index every other foreign column has.
    static let v2 = """
        CREATE TABLE "lecture_deck_span_v2" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "lecture_id" TEXT NOT NULL REFERENCES "lecture"("id") ON DELETE CASCADE,
          "deck_id" TEXT NOT NULL REFERENCES "deck"("id") ON DELETE CASCADE,
          "first_page" INTEGER,
          "last_page" INTEGER,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE SET NULL,
          "start_time" REAL,
          "end_time" REAL,
          "source" TEXT NOT NULL DEFAULT 'auto',
          "confidence" REAL NOT NULL DEFAULT 1,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        INSERT INTO "lecture_deck_span_v2"
          ("id", "lecture_id", "deck_id", "first_page", "last_page", "recording_id",
           "start_time", "end_time", "source", "confidence", "updated_at")
          SELECT "id", "lecture_id", "deck_id", "first_page", "last_page", "recording_id",
                 "start_time", "end_time", "source", "confidence", "updated_at"
          FROM "lecture_deck_span";
        DROP TABLE "lecture_deck_span";
        ALTER TABLE "lecture_deck_span_v2" RENAME TO "lecture_deck_span";
        CREATE INDEX "lecture_deck_span_lecture" ON "lecture_deck_span"("lecture_id", "start_time");
        CREATE INDEX "lecture_deck_span_deck" ON "lecture_deck_span"("deck_id");
        CREATE INDEX "lecture_deck_span_recording" ON "lecture_deck_span"("recording_id");
        """

    /// v3: `job.phase`, what a running job is doing before its own work starts (e.g. downloading
    /// the transcription model), so its progress bar can say so. NULL = the stage itself.
    static let v3 = """
        ALTER TABLE "job" ADD COLUMN "phase" TEXT;
        """

    /// v4 (milestone 1): semesters, course setup fields, session planning + calendar sync state,
    /// review state, filing provenance, and the search index.
    ///
    /// - `semester` (seeded with WS 2026/27 under a fixed id) and `course.semester_id`;
    /// - `course`: `rules` (JSON `[CourseRule]`), `recording_scope`, `shows_in_calendar`,
    ///   `slides_folder` + `slides_folder_bookmark`;
    /// - `weekly_slot.week_interval`; `valid_from`/`valid_until` hold `YYYY-MM-DD` days from now on;
    /// - `lecture_session`: `number`, `edited_at`, `calendar_synced_at`;
    /// - `lecture`: `reviewed_at`, `review_position`;
    /// - `filing`: one row per imported file with source, confidence, signals and candidates;
    /// - `search_chunk` + FTS5 `search_fts` (unicode61, remove_diacritics 2, over text and
    ///   lemma_text) and `search_trigram` (trigram over text), both external-content tables kept
    ///   in step with `search_chunk` by triggers.
    static let v4 = """
        CREATE TABLE "semester" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL DEFAULT '',
          "lecture_start" TEXT NOT NULL,
          "lecture_end" TEXT NOT NULL,
          "breaks" TEXT NOT NULL DEFAULT '[]',
          "time_zone" TEXT NOT NULL DEFAULT '',
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        INSERT INTO "semester" ("id", "name", "lecture_start", "lecture_end", "breaks", "time_zone", "updated_at")
          VALUES ('57532026-2700-4000-8000-000000000001', 'Semester', '2026-10-05', '2027-01-29',
                  '[]', '',
                  '1970-01-01 00:00:00.000');

        ALTER TABLE "course" ADD COLUMN "semester_id" TEXT REFERENCES "semester"("id") ON DELETE SET NULL;
        ALTER TABLE "course" ADD COLUMN "rules" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]';
        ALTER TABLE "course" ADD COLUMN "recording_scope" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT 'lecturer';
        ALTER TABLE "course" ADD COLUMN "shows_in_calendar" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1;
        ALTER TABLE "course" ADD COLUMN "slides_folder" TEXT;
        ALTER TABLE "course" ADD COLUMN "slides_folder_bookmark" BLOB;
        UPDATE "course" SET "semester_id" = '57532026-2700-4000-8000-000000000001';
        CREATE INDEX "course_semester" ON "course"("semester_id");

        ALTER TABLE "weekly_slot" ADD COLUMN "week_interval" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1;
        UPDATE "weekly_slot" SET "valid_from" = substr("valid_from", 1, 10) WHERE "valid_from" IS NOT NULL;
        UPDATE "weekly_slot" SET "valid_until" = substr("valid_until", 1, 10) WHERE "valid_until" IS NOT NULL;

        ALTER TABLE "lecture_session" ADD COLUMN "number" INTEGER;
        ALTER TABLE "lecture_session" ADD COLUMN "edited_at" TEXT;
        ALTER TABLE "lecture_session" ADD COLUMN "calendar_synced_at" TEXT;
        CREATE INDEX "lecture_session_slot" ON "lecture_session"("weekly_slot_id");

        ALTER TABLE "lecture" ADD COLUMN "reviewed_at" TEXT;
        ALTER TABLE "lecture" ADD COLUMN "review_position" REAL;

        CREATE TABLE "filing" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "kind" TEXT NOT NULL DEFAULT 'deck',
          "file_name" TEXT NOT NULL DEFAULT '',
          "blob_sha256" TEXT NOT NULL DEFAULT '',
          "course_id" TEXT REFERENCES "course"("id") ON DELETE CASCADE,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE CASCADE,
          "lecture_session_id" TEXT REFERENCES "lecture_session"("id") ON DELETE SET NULL,
          "deck_id" TEXT REFERENCES "deck"("id") ON DELETE CASCADE,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE CASCADE,
          "source" TEXT NOT NULL DEFAULT 'auto',
          "confidence" REAL NOT NULL DEFAULT 0,
          "signals" TEXT NOT NULL DEFAULT '[]',
          "candidates" TEXT NOT NULL DEFAULT '[]',
          "created_lecture" INTEGER NOT NULL DEFAULT 0,
          "created_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec')),
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "filing_course" ON "filing"("course_id");
        CREATE INDEX "filing_lecture" ON "filing"("lecture_id");
        CREATE INDEX "filing_session" ON "filing"("lecture_session_id");
        CREATE INDEX "filing_deck" ON "filing"("deck_id");
        CREATE INDEX "filing_recording" ON "filing"("recording_id");
        CREATE INDEX "filing_created" ON "filing"("created_at");

        CREATE TABLE "search_chunk" (
          "id" INTEGER PRIMARY KEY,
          "kind" TEXT NOT NULL,
          "source_id" TEXT NOT NULL,
          "course_id" TEXT REFERENCES "course"("id") ON DELETE CASCADE,
          "lecture_id" TEXT REFERENCES "lecture"("id") ON DELETE CASCADE,
          "deck_id" TEXT REFERENCES "deck"("id") ON DELETE CASCADE,
          "page_number" INTEGER,
          "recording_id" TEXT REFERENCES "recording"("id") ON DELETE CASCADE,
          "note_id" TEXT REFERENCES "note"("id") ON DELETE CASCADE,
          "start_time" REAL,
          "end_time" REAL,
          "lang" TEXT NOT NULL DEFAULT '',
          "text" TEXT NOT NULL DEFAULT '',
          "lemma_text" TEXT NOT NULL DEFAULT '',
          "source_updated_at" TEXT,
          "updated_at" TEXT NOT NULL DEFAULT (datetime('now', 'subsec'))
        ) STRICT;
        CREATE INDEX "search_chunk_source" ON "search_chunk"("kind", "source_id");
        CREATE INDEX "search_chunk_course" ON "search_chunk"("course_id");
        CREATE INDEX "search_chunk_lecture" ON "search_chunk"("lecture_id");
        CREATE INDEX "search_chunk_deck" ON "search_chunk"("deck_id", "page_number");
        CREATE INDEX "search_chunk_recording" ON "search_chunk"("recording_id", "start_time");
        CREATE INDEX "search_chunk_note" ON "search_chunk"("note_id");

        CREATE VIRTUAL TABLE "search_fts" USING fts5(
          "text", "lemma_text",
          content = 'search_chunk', content_rowid = 'id',
          tokenize = 'unicode61 remove_diacritics 2',
          prefix = '2 3'
        );
        CREATE VIRTUAL TABLE "search_trigram" USING fts5(
          "text",
          content = 'search_chunk', content_rowid = 'id',
          tokenize = 'trigram'
        );

        CREATE TRIGGER "search_chunk_after_insert" AFTER INSERT ON "search_chunk" BEGIN
          INSERT INTO "search_fts" ("rowid", "text", "lemma_text") VALUES (new."id", new."text", new."lemma_text");
          INSERT INTO "search_trigram" ("rowid", "text") VALUES (new."id", new."text");
        END;
        CREATE TRIGGER "search_chunk_after_delete" AFTER DELETE ON "search_chunk" BEGIN
          INSERT INTO "search_fts" ("search_fts", "rowid", "text", "lemma_text") VALUES ('delete', old."id", old."text", old."lemma_text");
          INSERT INTO "search_trigram" ("search_trigram", "rowid", "text") VALUES ('delete', old."id", old."text");
        END;
        CREATE TRIGGER "search_chunk_after_update" AFTER UPDATE OF "text", "lemma_text" ON "search_chunk" BEGIN
          INSERT INTO "search_fts" ("search_fts", "rowid", "text", "lemma_text") VALUES ('delete', old."id", old."text", old."lemma_text");
          INSERT INTO "search_trigram" ("search_trigram", "rowid", "text") VALUES ('delete', old."id", old."text");
          INSERT INTO "search_fts" ("rowid", "text", "lemma_text") VALUES (new."id", new."text", new."lemma_text");
          INSERT INTO "search_trigram" ("rowid", "text") VALUES (new."id", new."text");
        END;
        """
}
