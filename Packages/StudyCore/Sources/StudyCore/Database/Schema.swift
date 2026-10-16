import Foundation
import SQLiteData

/// Schema migrations. Append new migrations; never edit a shipped one.
///
/// CloudKit-friendly rules (SQLiteData SyncEngine, docs/schema.md):
/// UUID TEXT primary keys, no UNIQUE constraints/indexes besides the primary key,
/// `ON DELETE` only CASCADE / SET NULL, columns added later must be nullable or have
/// `NOT NULL ON CONFLICT REPLACE DEFAULT …`, no CloudKit-reserved column names.
public enum Schema {
    public static let migrationIDs = ["v1"]

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        return migrator
    }

    /// Every table created by the migrations, in creation order.
    public static let tableNames = [
        "course", "weekly_slot", "lecture_session", "deck", "deck_page", "lecture", "recording",
        "lecture_deck_span", "recording_segment", "slide_event", "transcript_segment", "api_call",
        "note", "annotation", "tracked_item", "job",
    ]

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
}
