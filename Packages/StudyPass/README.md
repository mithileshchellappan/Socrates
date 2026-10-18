# StudyPass

The AI study pass (PRD M4: #10 corrections, #11 said in class but not on the slides, #12 exam hints, #18 pins, #21 summaries, #24 further reading). Scope, contracts and acceptance: [docs/plan-m4.md](../../docs/plan-m4.md) §1–4 (workstream A, §7).

Depends on StudyCore, ClaudeKit, Agent (`Deadlines` only: `TranscriptQuote`, `TextFolding`) and Capture (`SlidePageRenderer`). Never reads mail tables, never links MailIntelligence. No tests: verification is that it builds.

## Surface

- `actor StudyPassPipeline(services:client:now:)`: `start()`, `wake()`, `prefer(_ lectureID:)`, `stop()`.
- `StudyPass.promptVersion` (part of every unit's `input_hash`).

## Rows

- `study_unit` (`StudyUnit`): one per (lecture, stage, key); `StudyStage` read / synthesize / research; state `ExtractionState`.
- `annotation` with `study_unit_id`: the kinds and layers of plan §2 (`Values+M4.swift` in StudyCore).
- `transcript_segment.patches` (`[TranscriptPatch]`), always saved through `TranscriptSegment.withPatches`.
- `api_call.purpose` = `StudyStage.callPurpose` (`study.read`, `study.synthesize`, `study.research`), always with `lecture_id`.

## Requests for the integrator

(none yet)
