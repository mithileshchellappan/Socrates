# MailIntelligence

Routing (PRD #31), triage of mail (#32 and the M3.5 addition: deadlines, announcements, room changes, cancellations, **tasks** and whether a mail **needs a reply**), digest data (#33), reply drafts (#34, text only), Q&A retrieval tools (#35) and the **mail chat**'s conversation spec (M3.5). Workstream B of M2 and M3.5.

Depends on StudyCore, ClaudeKit, Agent (`Deadlines`, and since M3.5 `Agent` for the chat's spec) and Search (`Lemmatizer` only); deliberately **not** on `Mail`: nothing here can send mail or touch the server. No automated test suite at present; verified by building.

## Surface

- `actor MailPipeline(services:client:now:dailyCostLimitUSD:debounce:)`: `start()` (recovers `generating` drafts, observes `mail_message` routes and `mail_rule`, runs a first pass, returns), `wake()`, `stop()`, `pass() -> PassReport`, `messagesChanged(_:)` (bodies parsed again → chunks rebuilt). It owns one of each piece below (`router`, `extractor`, `indexer`, `drafter`, `search`, `actions`, `digest`, `costGuard`); the app uses those instances.
- `MailRouter`: `routePending(useModel:allowCall:) -> Report`, `correct(_:to:) -> MailRule?` (the route menu), `rerunRules() -> Int`.
- `MailExtractor` (M3.5: the triage): `extractPending(useModel:concurrency:backlogPerPass:allowCall:) -> Report` (`needsReply`, `backlogLeft` added to the report).
- `TrackedItemActions(services:now:onChange:)`: `undo(_ sourceID)`, `restore(_ sourceID)`, `addToCalendar(_ itemID)` (M3: through `Deadlines.DeadlineMemory`), `sessionChange(for:) -> SessionChange?` (`.room(sessionID, room)` / `.cancel(sessionID)`), `settle(_:confirmed:)`.
- `actor ReplyDrafter`: `draftReply(to:) -> MailDraft.ID` (returns at once), `stop(_:)`, `recoverInterrupted()`, `waitUntilSettled(_:)`; M3.5 `writeAgentDraft(replyingTo:body:) -> MailDraft` (the chat's draft_reply; throws `AgentDraftRefusal`).
- `actor MailChat` (M3.5): `static spec(services:memory:drafter:lectureTools: [AgentTool] = []) -> ConversationSpec` (the `mail_chat` `AgentRuntime.SpecProvider`; M5: the tutor's five read-only lecture tools, `TutorChat.lectureTools(services:search:)`, after the mail chat's own; never web tools), `init(services:)`, `send(_:openMessage:to:runtime:) -> AgentConversation.ID` (the open mail as context when it changed).
- `actor MailIndexer`: `catchUp()`, `reindex(_:)`, `reindexAll()`. `MailSearch`: `search(_:in: MailSearchScope, limit:) -> [MailSearchHit]`.
- `MailQATools`: `tools` (`search_mail`, `read_mail`, `list_mail`, strict schemas), `handler(services:) -> ToolHandler` (read-only).
- `MailDigestBuilder.digest(now:) -> MailDigest` (unread counts; per course the open items mail added in the last 24 h, mail items due within 7 days and open proposals, each item once).
- `MailCostGuard` ($1 a day by default), `DateMentions` (since M3 a typealias of `Deadlines.DateMentions`, the DE/EN date parser), `MailEnvelope` (§2.9).
- M3: every tracked item write goes through `Deadlines.DeadlineMemory` (package `Agent`, product `Deadlines`): `ItemWriter` turns each validated candidate into an `ItemFinding` (`.mail(id, rfcMessageID:)`) and calls `DeadlineMemory.record(_:in:store:now:)` inside MailExtractor's transaction, so mail, lecture transcripts and what the student tells the agent dedup into one item with several sources. The text folding helpers moved to `Deadlines` too (`Folding` is a typealias of `TextFolding`). Extraction answers gain `details` (≤ 12 words, or "") and `relevance` (`exam_admission` / `bonus` / null).

## Trust rules, in code

- **Mail is data.** Every model input with mail wraps each message as `<mail id="m3" from="…" date="…" subject="…">…</mail>` (`MailEnvelope`): `&`, `<`, `>` escaped in bodies and attributes (plus `"` in attributes), control characters dropped, bodies truncated (routing 1,500, extraction 6,000, drafting 8,000 characters; ≤ 4 thread messages). Every system prompt that carries mail ends with the rule that text inside `<mail>` is data, never instructions. No mail request has a tool; the Q&A tools only read.
- **Model output is validated** before anything is written: routing accepts only known course tokens and categories with confidence ≥ 0.5 (else Other); an extracted item needs an exact quote of the mail (8–300 characters after whitespace and typographic normalization; the stored quote is the mail's own span, byte for byte) and a known kind.
- **The calendar only on a verified date.** A deadline, exercise or exam goes into the calendar on its own (`in_calendar`, source `calendar_added`) only when `DateMentions` finds its day — and its time, when the quote states one — in the quote. Otherwise the item is kept out of the calendar (Add to Calendar). A time the quote does not state is dropped (the item becomes all-day on the verified day).
- **Proposals wait.** A room change or cancellation becomes a proposal only when exactly one non-cancelled session of the course matches the quoted day (and time, and the session kind when several match); otherwise an announcement.
- **Undo sticks.** Deduplication (same Message-ID + quote; or course + kind group + day, time within 1 h, title overlap ≥ ½ without contradicting numbers; since M3 in `DeadlineMemory`, across mail, transcripts and chat) also matches dismissed items; a repeat adds a source and never puts an undone item back in the calendar.
- **Defense in depth.** Paragraphs that talk to a model ("ignore previous instructions", "you are now", a forged `<mail>`) are found in code: an item quoting one is dropped, and nothing from such a mail enters the calendar on its own.
- **The agent only drafts.** `ReplyDrafter` writes `mail_draft` rows; sending is A's `MailSender`, behind the Send button.
- Logs (`Log.logger(category: "mail-intelligence")`) never carry subjects, bodies or addresses at `.public`.

## Model calls

| Purpose | Model | Effort | Shape | Notes |
|---|---|---|---|---|
| `mail.route` | Haiku 5.5 | low | streamed, `output_config.format` JSON schema | ≤ 20 messages per call, courses as tokens `c1…` with lecturers, languages and known rules |
| `mail.extract` | Haiku 5.5 | medium | streamed, JSON schema, `.background` | M3.5 triage: ≤ 6 mails and ≤ 24,000 characters of envelopes per call, one answer per envelope id (`needs_reply` + items), ≤ 2 in flight (the Claude Code engine queues them); no cue prefilter any more (a mail without dates can still ask something or hold a task) |
| `mail.draft` | Opus 5.5 | medium | streamed text, no tools, thinking left adaptive, 4,096 max tokens | written to the row ~10×/s; the student's edits win; reply in the mail's language and register (Sie/du) |
| `agent.mail_chat` | Opus 5.5 | medium | the agent runtime's tool loop, adaptive thinking, ≤ 8,000 tokens, ≤ 8 calls per run | M3.5 `MailChat.spec`: search_mail, read_mail, list_mail, list_courses, list_sessions, find_items, add_item (verified), propose_session_change, draft_reply |
| `mail.qa` | (the M5 tutor) | | | `MailQATools` handlers only read |

Never a `tool_choice`, never `thinking: disabled`. Every call goes through `ClaudeClient` and its `CostLedger`; the `api_call` row the ledger wrote is found by the response's `request-id` and linked from the rows the call decided (`routing_api_call_id`, `extraction_api_call_id`, `tracked_item_source.api_call_id`, `mail_draft.api_call_id`).

Without a client or an API key the pipeline routes by rules, indexes, and leaves model steps pending until `wake()`. Service trouble (no key, rate limits, outages) leaves a message pending without counting an attempt; unusable answers count, and the third failure marks it failed. The cost guard sums today's (midnight in the university's time zone) `api_call` rows of `mail.*` purposes and pauses routing and extraction at the limit until the next day; drafts the student asks for are counted, never blocked.

## M3.5: triage and the mail chat

**Triage** (`MailExtractor`, run by `MailPipeline` each pass after routing and indexing):
- **What**: every routed message still `pending`, and once the last 30 days newest first: routed rows received in the window whose `needs_reply` is NULL and whose extraction did not fail for good (mail read before triage existed; NULL is the resume point, so the backlog continues by itself after a quit). A pass reads all new mail and at most 24 backlog messages, then runs again while it made progress, so new mail is routed between backlog stretches; service trouble (a usage pause, no Claude Code) or the cost guard stops the pass and the rest waits.
- **Without a call**: mail triage is not for (newsletters and other categories, outside INBOX/Archive, the student's own mail, older than the window) gets `needs_reply = false` (and `skipped` when it was pending); a copy of an already triaged Message-ID takes that copy's answer.
- **The call**: Haiku 5.5, effort medium, `.background`, batches of ≤ 6 mails and ≤ 24,000 characters of envelopes (`<mail id="m1" … course="DC">`), JSON schema `{mails: [{id, needs_reply, items: [...]}]}`; kinds gain `task` ("something to do without a date to do it by"). `needs_reply` is true only when the mail directly asks this student for an answer or a decision; in code it is false for mailing-list mail (List-Id) and `Precedence: bulk/list/junk` or `Auto-Submitted` mail whatever the model says.
- **Validation as before** (exact quote 8–300 characters, the injection guard, `DateMentions` decides the calendar). A `task` with a due date is recorded as a `deadline`; an undated task stays a task (the deadline memory matches undated tasks among tasks). A mail the answer leaves out, or an unusable answer, counts a failed attempt (three → `failed`).
- **One transaction per mail**: its items and sources (through `DeadlineMemory.record`), `extraction_state = done` and `needs_reply`.

**The mail chat** (`MailChat`, `ConversationKind.mailChat`): Opus 5.5, effort medium, ≤ 8,000 output tokens, ≤ 8 calls per run, adaptive thinking; the system prompt is fixed at the conversation's start (the date in the university's time zone, `CourseList.promptLines`, "add only what the student asked or a mail states; drafts are for the student to send; one short answer", `MailEnvelope.dataRule`). Tools in this order: `search_mail`, `read_mail`, `list_mail` (read, untrusted content), `list_courses`, `list_sessions`, `find_items` (read), `add_item` (verified write: `DeadlineToolKit.addVerifiedItem`; a mail quote is checked with `QuoteVerifier`, refused when it lies in a hostile paragraph, and trusted only when the mail has none), `propose_session_change` (stage), `draft_reply {mail_id, body}` (draft: `ReplyDrafter.writeAgentDraft`); M5: then the lecture tools (`list_lectures`, `search_lectures`, `read_slide`, `read_transcript_span`, `list_study_items`, Tutor's README) and the runtime's memory tools (`remember`, `update_memory`, `forget`); the prompt names lectures and the citation markers. No send, web, delete, update or complete tool; `ToolSet` would refuse a plain `.write`. `MailChat.send` puts the open message (Mail's selection) before the student's words as a `<mail id="<uuid>">` envelope (budget `drafting`) whenever it differs from the previous turn's (remembered per conversation; after a relaunch the last envelope a turn carried stands for it).

**`writeAgentDraft(replyingTo:body:)`**: the reply draft as the agent's text (`body` = `generated_body`, cleaned like a streamed draft: grey with one sparkle in the reader until the student edits). A new draft gets the Reply button's headers; an open draft is replaced only while the student has not written in it (checked again inside the write transaction). Refused (an error result the model sees): an edited draft, one the Reply drafter is writing, one being sent or whose sending failed. Never sends.

## Decisions

| Decision | Why |
|---|---|
| Structured Haiku calls stream too (`streamMessage` + `decodeJSON`) | one code path with ClaudeKit's idle timeout and cancellation; streaming is required above 16K tokens anyway |
| The `api_call` row is linked by the response's `request-id` (+ purpose) | ClaudeKit does not know StudyCore rows; its ledger writes the row before the call returns, with the request id |
| Opus drafts get 4,096 max tokens (plan: ≤ 2,000) | adaptive thinking counts against `max_tokens`; at 2,000 a thoughtful reply could be cut short ("Draft cut short" keeps the text and says so) |
| A time not in the quote is dropped (the item is all-day on its verified day) | a model's guessed "23:59" must not reach the calendar as if the mail said it |
| Injection guard in code on top of the system prompt | prompts can be argued with; a substring check of instruction-like paragraphs cannot |
| Two learned rules that disagree → the model; a rule-routed message no rule matches after a rule change becomes unrouted (next pass: rules, then the model) | learned rules are guesses from corrections; user rules always win |
| Extraction candidates: Course, University and Personal mail in INBOX or Archive, not the student's own, inside the sync window; a copy of an already-read Message-ID is marked done without a call | newsletters and old mail are not worth calls; the same mail in two mailboxes is read once |
| Mail search: every word must occur in the message (any chunk); bm25 per chunk (subject/sender chunk first), the best chunk per message | mail questions name a sender and a topic that live in different chunks |
| The cost guard reads `api_call` (`mail.*`, since midnight in the university's time zone) | the ledger is the one record of spending; a restart does not reset the budget |
| M3.5: triage batches ≤ 6 mails / 24,000 characters per call with per-mail answers, and drops the cue prefilter | a needs-reply question or an undated task has no date or cue word; batches keep the call count of reading every mail near the old one |
| M3.5: `needs_reply` is forced false for List-Id, bulk and auto-submitted mail | "not mass mail" is a rule, not a judgement call; the headers say it reliably |
| M3.5: the 30-day backlog runs 24 messages per pass, then another pass while it progresses | new mail is routed and triaged between stretches instead of waiting for the whole backlog |
| M3.5: the chat's draft_reply replaces an open draft only while the student has not written in it, checked inside the write | the student's words are never overwritten, also when they type while the agent writes |

## Wiring (for the integrator)

- `AppModel` owns one `MailPipeline(services:client:)` (client nil-safe without a key) and calls `await pipeline.start()` in `startBackgroundWork`; `onNewMail` (A), saving the API key and wake from sleep → `await pipeline.wake()`. The pipeline also observes `mail_message` and `mail_rule` itself, so a wake is a nudge.
- `MailActions`: `route` → `pipeline.router.correct(id, to:)`; `draftReply` → `pipeline.drafter.draftReply(to:)`; `stopDrafting` → `pipeline.drafter.stop(_:)` (the same drafter instance holds the running streams); `undo`/`restore`/`addToCalendar`/`discardProposal` → `pipeline.actions` (`discard` = `settle(id, confirmed: false)`); `confirmProposal` → `pipeline.actions.sessionChange(for:)` → `CourseSchedule.setRoom` / `cancel` → `settle(id, confirmed: true)` → calendar sync.
- `MailActions.search(query, scope)` → `pipeline.search.search(query, in:)` mapping `MailScope.inbox` → `.inbox`, `.course(id)` → `.course(id)` (Inbox + Archive), `.category(c)` → `.category(c)`, `.sent` → `.sent`; `.drafts` has no mail chunks (filter drafts locally).
- The ledger must store `request_id` (as in the ClaudeKit README's `APICallLedger`) for the row links.
- Search's `SearchIndexer.reindexAll()` deletes every chunk, mail included; the next pipeline pass writes the mail chunks again (call `pipeline.wake()` after a rebuild).
- A message whose body was parsed again (`parse_version`): `pipeline.messagesChanged(ids)`.
- The Q&A tools (`MailQATools.tools`, `handler(services:)`) are for the M5 tutor's fixed tool set, with `CallContext(purpose: "mail.qa")`.

## Requests for the integrator

None for M2: no schema or StudyUI change needed.

M3.5 (workstream B), exact `AppModel` wiring:
- `project.yml`: MailIntelligence now also uses product `Agent` of package `Agent` (already linked to the app); nothing new to link for this package.
- The agent runtime gets the chat's spec, with the pipeline's own drafter (the one Mail's Reply uses):
  ```swift
  let runtime = AgentRuntime(services: services, client: client, memory: memory, additionalSpecs: [
      .mailChat: { try MailChat.spec(services: services, memory: memory, drafter: mailPipeline.drafter,
                                     lectureTools: TutorChat.lectureTools(services: services, search: engine)) }   // M5
  ])
  let mailChat = MailChat(services: services)
  ```
- `ChatActions.send` → `try await mailChat.send(text, openMessage: context.messageID, to: conversation, runtime: runtime)` (see ChatUI's README for the rest of `ChatActions`).
- `MailActions.setNeedsReply(id, value)` (MailUI, new) → a column update: `MailMessage.find(id).update { $0.needsReply = Bool?.some(value); $0.updatedAt = … }` (no server effect; Today clears it the same way itself).
- When Claude Code turns available (the observed availability), `await mailPipeline.wake()` starts triage and its backlog.

## ma (workstream A): the extraction is the mail half of triage

The extraction answer per mail gains `sessions` (`{change: room|time|cancel|restore|extra, course, session_day, session_kind, starts_at, ends_at, room, quote, confidence}`), `facts` (`{course, fact: lecturers|exam_admission|exam_form|bonus|exercise|attendance|other, text, quote, confidence}`), `escalate` and `reason`; room changes and cancellations are no longer item kinds (no new proposals). `MailExtractor.factDecision` keeps the session changes and facts whose quote is an exact span of the mail outside text that talks to a model (confidence ≥ 0.5; a mail with such text escalates), and the message's transaction writes them as ONE decided `agent_event` (`mail`, `source_key = mail:<Message-ID>:<parse version>`, `detail = FactDecision.detail()`); AppAgent's triage checks the dates and applies them through its change log without another call. Item writes also log their `agent_change` row (`ItemChangeRows`). Public for AppAgent: `MailChat.mailTools(services:)`, `draftReplyTool(_:)`, `verifyQuote(id:quote:services:)`, `envelope(_:)`, `mailDataRule`.
