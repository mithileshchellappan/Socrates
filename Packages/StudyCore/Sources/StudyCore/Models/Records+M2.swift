import Foundation
import SQLiteData

// Record types added in schema v5 (milestone 2): the uni mail account, its mailboxes and
// messages, attachments, routing rules, reply drafts, and where tracked items came from.
//
// Trust rules (PRD): no secret is ever stored here (the password lives in the Keychain under
// `MailAccount.keychainItem`); mail content is untrusted data; only the Send button sends.

// MARK: - Account

/// The student's university mail account (one in M2). Holds no secret: the password is the
/// Keychain item named by `keychainItem` (`SecretKey.uniPassword(username:)`).
@Table("mail_account")
public struct MailAccount: StudyRecord {
    public let id: UUID
    /// "Sam Student" (From: name of sent mail).
    @Column("display_name") public var displayName: String
    /// The address mail is sent from (the student's alias, e.g. "…@students.example.org").
    @Column("email_address") public var emailAddress: String
    /// The uni account name used to log in to IMAP and SMTP (not the mail alias).
    public var username: String
    @Column("imap_host") public var imapHost: String
    @Column("imap_port") public var imapPort: Int
    @Column("imap_security") public var imapSecurity: MailSecurity
    @Column("smtp_host") public var smtpHost: String
    @Column("smtp_port") public var smtpPort: Int
    @Column("smtp_security") public var smtpSecurity: MailSecurity
    /// Tried when `smtpHost` cannot be reached (not after an authentication failure).
    @Column("smtp_fallback_host") public var smtpFallbackHost: String?
    @Column("smtp_fallback_port") public var smtpFallbackPort: Int?
    @Column("smtp_fallback_security") public var smtpFallbackSecurity: MailSecurity?
    /// `SecretKey.rawValue` of the password's Keychain item. Never the password itself.
    @Column("keychain_item") public var keychainItem: String
    /// First day the initial sync fetches (older mail stays on the server); nil = 30 days back.
    @Column("sync_since") public var syncSince: CalendarDay?
    /// False: nothing syncs (the student turned the account off, or it is not set up yet).
    @Column("is_enabled") public var isEnabled: Bool
    /// Last sync that reached the server.
    @Column("last_sync_at") public var lastSyncAt: Date?
    /// Why the last attempt failed (no secrets, no mail content); nil after a good sync.
    @Column("last_error") public var lastError: String?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        emailAddress: String = "",
        username: String,
        imapHost: String = MailAccount.exampleIMAPHost,
        imapPort: Int = 993,
        imapSecurity: MailSecurity = .tls,
        smtpHost: String = MailAccount.exampleSMTPHost,
        smtpPort: Int = 587,
        smtpSecurity: MailSecurity = .startTLS,
        smtpFallbackHost: String? = MailAccount.exampleSMTPFallbackHost,
        smtpFallbackPort: Int? = 465,
        smtpFallbackSecurity: MailSecurity? = .tls,
        keychainItem: String? = nil,
        syncSince: CalendarDay? = nil,
        isEnabled: Bool = true,
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.username = username
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.imapSecurity = imapSecurity
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        self.smtpFallbackHost = smtpFallbackHost
        self.smtpFallbackPort = smtpFallbackPort
        self.smtpFallbackSecurity = smtpFallbackSecurity
        self.keychainItem = keychainItem ?? SecretKey.uniPassword(username: username).rawValue
        self.syncSince = syncSince
        self.isEnabled = isEnabled
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Exampleton student mail (Dovecot, AUTH=PLAIN, IDLE).
    public static let exampleIMAPHost = "imap.students.example.org"
    /// Exampleton student submission server (587, STARTTLS).
    public static let exampleSMTPHost = "smtp.students.example.org"
    /// The university's general SMTP (465, TLS), when the students' server cannot be reached.
    public static let exampleSMTPFallbackHost = "smtp.example.org"

    /// The Keychain item holding the password.
    public var passwordKey: SecretKey { SecretKey(rawValue: keychainItem) }

    /// The sender of mail from this account.
    public var sender: MailAddress { MailAddress(name: displayName, address: emailAddress) }
}

/// One IMAP mailbox (folder) of an account and its sync checkpoint.
///
/// The checkpoint (`uidValidity`, `lastUID`) is written in the same transaction as the messages
/// it covers, so a crash mid-sync never skips or duplicates a message. A changed UIDVALIDITY
/// invalidates every stored UID of the mailbox (see docs/plan-m2.md).
@Table("mailbox")
public struct Mailbox: StudyRecord {
    public let id: UUID
    @Column("account_id") public var accountID: MailAccount.ID
    /// Server path, e.g. "INBOX", "Sent", "INBOX/Archive" (modified UTF-7 decoded).
    public var path: String
    /// Last path component, for display.
    public var name: String
    /// Hierarchy delimiter ("/" or "."), when the server gave one.
    public var delimiter: String?
    /// SPECIAL-USE role, or `.inbox`; nil = ordinary folder.
    public var role: MailboxRole?
    /// True when messages of this mailbox are synced (INBOX, Sent, Archive in M2).
    @Column("is_synced") public var isSynced: Bool
    /// IMAP UIDVALIDITY of the stored UIDs; nil before the first sync.
    @Column("uid_validity") public var uidValidity: Int64?
    /// CONDSTORE HIGHESTMODSEQ: the QRESYNC checkpoint of the last pass (nil without CONDSTORE).
    @Column("highest_modseq") public var highestModSeq: Int64?
    /// Highest UID stored; new mail is UID > lastUID.
    @Column("last_uid") public var lastUID: Int64
    /// Server UIDNEXT at the last sync.
    @Column("uid_next") public var uidNext: Int64?
    /// Earliest day fetched (older mail is not in the library).
    @Column("synced_since") public var syncedSince: CalendarDay?
    @Column("last_synced_at") public var lastSyncedAt: Date?
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: MailAccount.ID,
        path: String,
        name: String? = nil,
        delimiter: String? = nil,
        role: MailboxRole? = nil,
        isSynced: Bool = false,
        uidValidity: Int64? = nil,
        highestModSeq: Int64? = nil,
        lastUID: Int64 = 0,
        uidNext: Int64? = nil,
        syncedSince: CalendarDay? = nil,
        lastSyncedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.path = path
        self.name = name ?? delimiter.flatMap { path.components(separatedBy: $0).last } ?? path
        self.delimiter = delimiter
        self.role = role
        self.isSynced = isSynced
        self.uidValidity = uidValidity
        self.highestModSeq = highestModSeq
        self.lastUID = lastUID
        self.uidNext = uidNext
        self.syncedSince = syncedSince
        self.lastSyncedAt = lastSyncedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Messages

/// One mail message in one mailbox (a message copied to two mailboxes is two rows with the same
/// `rfcMessageID`). Untrusted content: pass `subject`/`bodyText` to models only as delimited data.
@Table("mail_message")
public struct MailMessage: StudyRecord {
    public let id: UUID
    @Column("account_id") public var accountID: MailAccount.ID
    @Column("mailbox_id") public var mailboxID: Mailbox.ID
    /// IMAP UID in `mailboxID` under its current UIDVALIDITY; nil while unknown (after a
    /// UIDVALIDITY change or a pending move, until the next sync finds it again).
    public var uid: Int64?
    /// RFC 5322 Message-ID without angle brackets ("abc@lms.example.org"); empty if missing.
    @Column("rfc_message_id") public var rfcMessageID: String
    /// In-Reply-To Message-ID without angle brackets; empty if none.
    @Column("in_reply_to") public var inReplyTo: String
    /// References Message-IDs, oldest first.
    @Column("reference_ids", as: [String].JSONRepresentation.self) public var referenceIDs: [String]
    /// The thread: the root Message-ID (References[0] ?? the parent's thread ?? In-Reply-To ?? own).
    @Column("thread_id") public var threadID: String
    @Column("from_name") public var fromName: String
    @Column("from_address") public var fromAddress: String
    @Column("reply_to", as: [MailAddress].JSONRepresentation.self) public var replyTo: [MailAddress]
    @Column("to_addresses", as: [MailAddress].JSONRepresentation.self) public var to: [MailAddress]
    @Column("cc_addresses", as: [MailAddress].JSONRepresentation.self) public var cc: [MailAddress]
    /// Decoded subject (RFC 2047).
    public var subject: String
    /// The Date header.
    @Column("sent_at") public var sentAt: Date?
    /// IMAP INTERNALDATE (when the server received it): list order.
    @Column("received_at") public var receivedAt: Date
    @Column("is_seen") public var isSeen: Bool
    @Column("is_flagged") public var isFlagged: Bool
    @Column("is_answered") public var isAnswered: Bool
    /// Other flags and keywords as the server spells them ("$Forwarded", "$Junk", "\\Draft").
    @Column(as: [String].JSONRepresentation.self) public var keywords: [String]
    /// Set when the flags above were changed here and not yet stored on the server; the next
    /// sync pushes them (local wins) and clears it.
    @Column("flags_changed_at") public var flagsChangedAt: Date?
    /// A move (Archive) waiting to be done on the server.
    @Column("move_to_mailbox_id") public var moveToMailboxID: Mailbox.ID?
    /// RFC822.SIZE in bytes.
    public var size: Int
    /// About 200 characters of `bodyText`, whitespace collapsed (message list).
    public var snippet: String
    /// Readable plain text (from text/plain, else from the sanitized HTML). What models, search
    /// and quote checks see.
    @Column("body_text") public var bodyText: String
    /// Sanitized HTML (docs/plan-m2.md allowlist) in the BlobStore; empty when the mail had none.
    @Column("html_sha256") public var htmlSHA256: String
    @Column("html_path") public var htmlPath: String
    /// The raw RFC 5322 message (.eml) in the BlobStore; empty when not stored (too large).
    @Column("raw_sha256") public var rawSHA256: String
    @Column("raw_path") public var rawPath: String
    /// Version of the parser that derived the body columns; a newer parser re-derives them from
    /// the raw blob.
    @Column("parse_version") public var parseVersion: Int
    /// "de", "en" or "" (detected from the body).
    public var language: String
    /// List-Id header (mailing lists), e.g. "linguistics.lists.example.org"; empty if none.
    @Column("list_id") public var listID: String
    /// Selected other headers routing and extraction use (Auto-Submitted, Precedence,
    /// List-Unsubscribe, X-Mailer, …), lower-cased names.
    @Column(as: [String: String].JSONRepresentation.self) public var headers: [String: String]
    /// The course it belongs to (category `course`).
    @Column("course_id") public var courseID: Course.ID?
    /// Nil until routed.
    public var category: MailCategory?
    @Column("routing_source") public var routingSource: MailRoutingSource?
    @Column("routing_rule_id") public var routingRuleID: MailRule.ID?
    /// 0…1 (rules 1, learned rules 0.9, the model's own).
    @Column("routing_confidence") public var routingConfidence: Double?
    @Column("routed_at") public var routedAt: Date?
    @Column("routing_api_call_id") public var routingAPICallID: APICall.ID?
    @Column("extraction_state") public var extractionState: MailExtractionState
    @Column("extraction_attempts") public var extractionAttempts: Int
    @Column("extracted_at") public var extractedAt: Date?
    @Column("extraction_api_call_id") public var extractionAPICallID: APICall.ID?
    /// v7 (M3.5 triage): the mail asks the student something they should answer. Nil until the
    /// message was triaged (also the backlog's resume point: the last 30 days' routed mail with
    /// nil is still to read); false when it asks nothing or the student cleared it. Shown while
    /// true and the message is not answered (`is_answered`, set when a reply is sent).
    @Column("needs_reply") public var needsReply: Bool?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: MailAccount.ID,
        mailboxID: Mailbox.ID,
        uid: Int64? = nil,
        rfcMessageID: String = "",
        inReplyTo: String = "",
        referenceIDs: [String] = [],
        threadID: String? = nil,
        fromName: String = "",
        fromAddress: String = "",
        replyTo: [MailAddress] = [],
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        subject: String = "",
        sentAt: Date? = nil,
        receivedAt: Date = Date(),
        isSeen: Bool = false,
        isFlagged: Bool = false,
        isAnswered: Bool = false,
        keywords: [String] = [],
        flagsChangedAt: Date? = nil,
        moveToMailboxID: Mailbox.ID? = nil,
        size: Int = 0,
        snippet: String = "",
        bodyText: String = "",
        htmlSHA256: String = "",
        htmlPath: String = "",
        rawSHA256: String = "",
        rawPath: String = "",
        parseVersion: Int = 0,
        language: String = "",
        listID: String = "",
        headers: [String: String] = [:],
        courseID: Course.ID? = nil,
        category: MailCategory? = nil,
        routingSource: MailRoutingSource? = nil,
        routingRuleID: MailRule.ID? = nil,
        routingConfidence: Double? = nil,
        routedAt: Date? = nil,
        routingAPICallID: APICall.ID? = nil,
        extractionState: MailExtractionState = .pending,
        extractionAttempts: Int = 0,
        extractedAt: Date? = nil,
        extractionAPICallID: APICall.ID? = nil,
        needsReply: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.mailboxID = mailboxID
        self.uid = uid
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.referenceIDs = referenceIDs
        self.threadID = threadID ?? referenceIDs.first ?? (inReplyTo.isEmpty ? rfcMessageID : inReplyTo)
        self.fromName = fromName
        self.fromAddress = fromAddress
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.subject = subject
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.isSeen = isSeen
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.keywords = keywords
        self.flagsChangedAt = flagsChangedAt
        self.moveToMailboxID = moveToMailboxID
        self.size = size
        self.snippet = snippet
        self.bodyText = bodyText
        self.htmlSHA256 = htmlSHA256
        self.htmlPath = htmlPath
        self.rawSHA256 = rawSHA256
        self.rawPath = rawPath
        self.parseVersion = parseVersion
        self.language = language
        self.listID = listID
        self.headers = headers
        self.courseID = courseID
        self.category = category
        self.routingSource = routingSource
        self.routingRuleID = routingRuleID
        self.routingConfidence = routingConfidence
        self.routedAt = routedAt
        self.routingAPICallID = routingAPICallID
        self.extractionState = extractionState
        self.extractionAttempts = extractionAttempts
        self.extractedAt = extractedAt
        self.extractionAPICallID = extractionAPICallID
        self.needsReply = needsReply
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Attempts after which extraction is marked failed instead of retried.
    public static let maximumExtractionAttempts = 3

    public var from: MailAddress { MailAddress(name: fromName, address: fromAddress) }

    /// The route the message has, when routed.
    public var route: MailRoute? {
        if let courseID { return .course(courseID) }
        if let category, category != .course { return .category(category) }
        return nil
    }

    public var html: BlobRef? { htmlSHA256.isEmpty ? nil : BlobRef(sha256: htmlSHA256, relativePath: htmlPath) }
    public var raw: BlobRef? { rawSHA256.isEmpty ? nil : BlobRef(sha256: rawSHA256, relativePath: rawPath) }
}

/// One attachment (or inline part with a Content-ID) of a message. The file is decoded from the
/// raw message into the BlobStore on first use; until then the blob columns are empty.
@Table("mail_attachment")
public struct MailAttachment: StudyRecord {
    public let id: UUID
    @Column("mail_message_id") public var mailMessageID: MailMessage.ID
    /// MIME part path ("2", "1.2"), the IMAP section of the part.
    public var part: String
    @Column("file_name") public var fileName: String
    @Column("mime_type") public var mimeType: String
    /// Decoded size in bytes (estimated from the encoded size until decoded).
    public var size: Int
    /// Content-ID without angle brackets (inline images); empty if none.
    @Column("content_id") public var contentID: String
    @Column("is_inline") public var isInline: Bool
    @Column("blob_sha256") public var blobSHA256: String
    @Column("blob_path") public var blobPath: String
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        mailMessageID: MailMessage.ID,
        part: String = "",
        fileName: String,
        mimeType: String = "application/octet-stream",
        size: Int = 0,
        contentID: String = "",
        isInline: Bool = false,
        blobSHA256: String = "",
        blobPath: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailMessageID = mailMessageID
        self.part = part
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.blobSHA256 = blobSHA256
        self.blobPath = blobPath
        self.updatedAt = updatedAt
    }

    public var blob: BlobRef? {
        blobSHA256.isEmpty ? nil : BlobRef(sha256: blobSHA256, relativePath: blobPath, byteCount: Int64(size))
    }
}

/// Routes matching mail to a course (or to a category such as University). Rules decide before
/// the model; user rules before learned ones. Replaces the v1 `course.mail_rules` JSON (copied
/// over by v5).
@Table("mail_rule")
public struct MailRule: StudyRecord {
    public let id: UUID
    /// The course matching mail goes to; nil for a category rule.
    @Column("course_id") public var courseID: Course.ID?
    /// Category for rules without a course (e.g. `.university` for the university's IT centre); nil with a course.
    public var category: MailCategory?
    public var kind: MailRuleKind
    /// Compared case-insensitively with diacritics folded, as a substring.
    public var pattern: String
    public var origin: MailRuleOrigin
    /// Display order within its course (Course Settings).
    @Column("sort_order") public var sortOrder: Int
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        courseID: Course.ID? = nil,
        category: MailCategory? = nil,
        kind: MailRuleKind,
        pattern: String,
        origin: MailRuleOrigin = .user,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.courseID = courseID
        self.category = category
        self.kind = kind
        self.pattern = pattern
        self.origin = origin
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Where matching mail goes; nil for a rule with neither course nor category.
    public var route: MailRoute? {
        if let courseID { return .course(courseID) }
        return category.map(MailRoute.category)
    }
}

/// A reply (or new message) being written. The agent may stream text into it (`generatedBody`
/// is what it wrote; where `body` differs, the student edited); only the Send button sends.
@Table("mail_draft")
public struct MailDraft: StudyRecord {
    public let id: UUID
    @Column("account_id") public var accountID: MailAccount.ID
    /// The message replied to; nil for a new message.
    @Column("mail_message_id") public var mailMessageID: MailMessage.ID?
    /// In-Reply-To Message-ID (without angle brackets); empty for a new message.
    @Column("in_reply_to") public var inReplyTo: String
    @Column("reference_ids", as: [String].JSONRepresentation.self) public var referenceIDs: [String]
    @Column("to_addresses", as: [MailAddress].JSONRepresentation.self) public var to: [MailAddress]
    @Column("cc_addresses", as: [MailAddress].JSONRepresentation.self) public var cc: [MailAddress]
    @Column("bcc_addresses", as: [MailAddress].JSONRepresentation.self) public var bcc: [MailAddress]
    public var subject: String
    /// The text that will be sent.
    public var body: String
    /// What the agent wrote (nil: the student wrote it all). The UI shows unchanged agent text in
    /// the AI style and edited text in the primary style.
    @Column("generated_body") public var generatedBody: String?
    /// Course context (for the agent, and for filing the sent copy).
    @Column("course_id") public var courseID: Course.ID?
    public var state: MailDraftState
    /// Why sending (or generating) failed; no secrets.
    public var error: String?
    /// Message-ID given to the sent message (set before SMTP starts; without angle brackets).
    @Column("rfc_message_id") public var rfcMessageID: String
    @Column("send_started_at") public var sendStartedAt: Date?
    @Column("sent_at") public var sentAt: Date?
    /// When the copy was appended to the Sent mailbox.
    @Column("sent_copy_saved_at") public var sentCopySavedAt: Date?
    /// The drafting call (Opus).
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: MailAccount.ID,
        mailMessageID: MailMessage.ID? = nil,
        inReplyTo: String = "",
        referenceIDs: [String] = [],
        to: [MailAddress] = [],
        cc: [MailAddress] = [],
        bcc: [MailAddress] = [],
        subject: String = "",
        body: String = "",
        generatedBody: String? = nil,
        courseID: Course.ID? = nil,
        state: MailDraftState = .draft,
        error: String? = nil,
        rfcMessageID: String = "",
        sendStartedAt: Date? = nil,
        sentAt: Date? = nil,
        sentCopySavedAt: Date? = nil,
        apiCallID: APICall.ID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.mailMessageID = mailMessageID
        self.inReplyTo = inReplyTo
        self.referenceIDs = referenceIDs
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.generatedBody = generatedBody
        self.courseID = courseID
        self.state = state
        self.error = error
        self.rfcMessageID = rfcMessageID
        self.sendStartedAt = sendStartedAt
        self.sentAt = sentAt
        self.sentCopySavedAt = sentCopySavedAt
        self.apiCallID = apiCallID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The student changed what the agent wrote (or wrote it all).
    public var isEditedByUser: Bool { generatedBody != body }

    /// `error` of a send whose outcome is unknown (interrupted and not found in Sent, or the
    /// server stopped answering after taking the message). Send asks before sending it again.
    public static let unknownSendOutcome = "It is not known whether this message went out."

    /// The last send may have gone out: sending again needs the student's confirmation.
    public var mayHaveBeenSent: Bool { state == .failed && error == Self.unknownSendOutcome }
}

// MARK: - Provenance of tracked items

/// One source of a tracked item: the mail (M2), transcript or chat (M3) it was read from, with
/// the exact quote. An item read from two mails has two rows; Undo acts through one of them.
@Table("tracked_item_source")
public struct TrackedItemSource: StudyRecord {
    public let id: UUID
    @Column("tracked_item_id") public var trackedItemID: TrackedItem.ID
    public var kind: SourceRef.Kind
    /// The mail it was read from (nil once that row is gone; `rfcMessageID` stays).
    @Column("mail_message_id") public var mailMessageID: MailMessage.ID?
    /// Message-ID of that mail (survives a re-sync that recreates the row); for a `timetable`
    /// source, the name of the `.ics` file it was read from.
    @Column("rfc_message_id") public var rfcMessageID: String
    /// Transcript sources (M3).
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    /// Seconds on the recording clock (M3).
    public var time: Double?
    /// The exact text the item was read from, verified to be a substring of the source.
    public var quote: String
    /// 0…1, the extractor's.
    public var confidence: Double
    /// This source put the item in the calendar on its own (Undo takes it out again).
    @Column("calendar_added") public var calendarAdded: Bool
    /// When the student undid what this source added.
    @Column("undone_at") public var undoneAt: Date?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    /// v6: the conversation a `chat` source came from (what the student told the agent).
    @Column("conversation_id") public var conversationID: AgentConversation.ID?
    /// v6: the item's fields before this source changed them (an update, a completion); Undo puts
    /// them back. Nil when this source created the item or only repeated it.
    @Column(as: TrackedItemSnapshot?.JSONRepresentation.self) public var previous: TrackedItemSnapshot?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        trackedItemID: TrackedItem.ID,
        kind: SourceRef.Kind,
        mailMessageID: MailMessage.ID? = nil,
        rfcMessageID: String = "",
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil,
        time: Double? = nil,
        quote: String,
        confidence: Double = 1,
        calendarAdded: Bool = false,
        undoneAt: Date? = nil,
        apiCallID: APICall.ID? = nil,
        conversationID: AgentConversation.ID? = nil,
        previous: TrackedItemSnapshot? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.trackedItemID = trackedItemID
        self.kind = kind
        self.mailMessageID = mailMessageID
        self.rfcMessageID = rfcMessageID
        self.lectureID = lectureID
        self.recordingID = recordingID
        self.time = time
        self.quote = quote
        self.confidence = confidence
        self.calendarAdded = calendarAdded
        self.undoneAt = undoneAt
        self.apiCallID = apiCallID
        self.conversationID = conversationID
        self.previous = previous
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
