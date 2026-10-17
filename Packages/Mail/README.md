# Mail

University mail transport (PRD #30, #34 Send): IMAP sync into `mailbox` / `mail_message`, MIME parsing, safe HTML, attachments, SMTP for drafts the student sends. Workstream A of M2. Runs on the Mac; the package compiles for iOS.

## Entry points (plan §2.7)

| Type | What it does |
|---|---|
| `MailSyncEngine(services:connector:onNewMail:configuration:clock:)` | `start()` (discover, first pass, IDLE on INBOX, 5-minute poll), `stop()`, `syncNow()`, `retry()`, `setSeen`, `setFlagged`, `archive`, `attachmentFile` |
| `MailSender(services:connector:clock:)` | `send(draftID)` (the Send button only), `recoverInterruptedSends()` (launch) |
| `MailAccountVerifier(connector:)` | `verify(account, password:)`: IMAP login (needs IDLE, UIDPLUS) and SMTP login; sends nothing |
| `MIMEParser.parse(_:)` / `MIMEParser.version` | headers (RFC 2047, groups), body (text/plain, format=flowed, charset fallbacks, else the sanitized HTML's text), attachments, forwarded messages, snippet, language, thread |
| `HTMLSanitizer.sanitize(_:)` / `text(fromSanitized:)` | the §2.8 fragment (allowlisted tags, `href` with http/https/mailto only); its plain text |
| `MailConnector`, `IMAPSession`, `SMTPSession` | the package's own transport protocols; `SwiftMailConnector` (the only file importing SwiftMail) in the app |

Wiring (integrator): `recoverInterruptedSends()` then `engine.start()` at launch on the Mac; `onNewMail` → the pipeline's `wake()`; wake from sleep → `syncNow()`; saving the account → `retry()`. `attachmentFile` returns a file named like the attachment under `<caches>/MailAttachments/<id>/`.

## Behaviour worth knowing

- **Secrets.** The password is read from `services.secrets` (`account.passwordKey`) right before each login and never kept, logged or stored; `MailCredentials` redacts itself.
- **Checkpoints.** Each batch of 25 messages is one transaction with `mailbox.last_uid`; the window (`sync_since`, default 30 days) is fetched newest first; `synced_since` is set when it is complete. QRESYNC (Dovecot) brings flag changes and expunges; without it, UID FETCH FLAGS and a UID SEARCH diff do.
- **Local changes win.** `setSeen`/`setFlagged`/`archive` write the row at once (`flags_changed_at`, `move_to_mailbox_id`) and the next pass (2 s later) stores them first. Archive: UID MOVE with COPYUID, else COPY + `\Deleted` + UID EXPUNGE; the Archive mailbox is created on first use.
- **Failures.** Network errors back off 2 s → 5 min and set `mail_account.last_error` ("Can’t reach …"), cleared by the next good pass. An authentication failure (or no saved password) stops the engine after that one attempt until `retry()`.
- **Send.** `draft|failed → sending` assigns the Message-ID before SMTP; Send twice sends once; 587 STARTTLS with the account name, 465 TLS only when 587 cannot be reached; afterwards the exact bytes go to Sent with `\Seen` (the next sync retries when that failed) and the replied message gets `\Answered`.

## Verification

No automated test suite at present; verified by building and rendering. A live check of a real account is the student's own: Settings ▸ Accounts ▸ Test Connection logs in to IMAP and SMTP and sends nothing.

## Requests for the integrator

Handled in the M2 integration: 1 (comment fixed); 2 (the app passes neither); 3 (unused: the UI reads `mail_account.last_error`). The list as written:

1. `Mailbox.highestModSeq`'s doc comment in StudyCore says "unused by SwiftMail 1.9"; it is used now (QRESYNC checkpoint). Comment only.
2. The engine and the sender take an optional `clock:` (and the engine `configuration:`) after the frozen parameters; the app passes neither.
3. `MailSyncEngine.state` (`.stopped`, `.running`, `.authenticationFailed`) is public if the app wants it; the UI can rely on `mail_account.last_error` instead.
