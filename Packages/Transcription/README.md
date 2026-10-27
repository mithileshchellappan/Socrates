# Transcription

On-device transcription of lecture recordings into timed, language-tagged segments (PRD feature 8).
WhisperKit (argmax-oss-swift 1.1.1, MIT) runs Whisper large-v3-turbo through Core ML; this package
adds chunking, per-chunk language choice, repair guards and the mapping to `transcript_segment` rows.

## Use

```swift
import Transcription

let engine = WhisperKitEngine(store: try .shared())          // model in Application Support/Socrates/Models
try await engine.prepare { progress in … }                   // first run: 1.6 GB download + Core ML compile (minutes)
let transcript = try await engine.transcribe(
    TranscriptionAudio(recording: recording, segments: recordingSegments) { segment in
        segment.blobPath.isEmpty ? nil : blobs.url(forRelativePath: segment.blobPath)
    },
    options: TranscriptionOptions(course: course)       // detect among course languages + de/en, glossary as prompt
) { progress in job.progress = progress.fractionCompleted }
try await transcripts.replaceSegments(recordingID: recording.id,
    with: transcript.records(recordingID: recording.id, lectureID: lecture.id))
```

- `TranscriptionEngine` (protocol): `prepare(progress:)`, `transcribe(_:options:progress:)`. Cancel the calling
  task to stop; the engine throws `CancellationError` between decoder batches.
- `TranscriptionOptions`: `language` (`.germanEnglish` = detect per chunk among de/en, the default;
  `.forced("en")`, `.detectAny`), `glossary` (course terms, sent as Whisper prompt tokens), `wordTimestamps`,
  `guards` (all on by default). `TranscriptionOptions(course:)` builds them from course setup.
- `Transcript`: `segments` (`TranscribedSegment`: start/end on the recording clock, text, language, words with
  times and probabilities, avgLogProb, noSpeechProb, compressionRatio, temperature, `repair`), `chunks`
  (language per ≤ 30 s chunk, loops found/remaining), `gaps` (speech the first pass dropped, recovered or not),
  `wallTime`.
- StudyCore mapping: `TranscribedSegment.record(recordingID:lectureID:)`, `Transcript.records(…)`,
  `TranscriptionAudio(recording:segments:files:)`.

## Pipeline (`GuardedTranscriber`)

A recording's segment files are loaded onto its clock as runs of continuous 16 kHz audio
(`AudioTimeline.runs` → `SampleTimeline`): a part within 1 s of the current run's end joins it, a
later one (after a pause or an interruption) starts a new run, so a gap is never held as samples.
Every read (frame levels, decode windows) gives zeros where no run lies, at the same sample offsets
as a zero-padded array, so the transcript and its times are the same; times are seconds from the
clock's sample 0.

1. Energy VAD with an adaptive noise floor (`SpeechActivityDetector`).
2. Chunks ≤ 30 s cut in the longest pause of each window's second half (`ChunkPlanner`); chunks with
   < 0.3 s of speech are not decoded.
3. First pass, 16 chunks at a time (`ChunkDecoder`; `WhisperKitDecoder` in production).
4. Loop guard: a chunk containing an n-gram repeated back to back (3–8 words ≥ 3×, 2 words ≥ 5×,
   1 word ≥ 8×) or a token looping inside itself ("Folle-Folle-Folle-…", ≥ 4 copies) is re-decoded at
   temperature 0.4, then 0.8, in its detected language and without the glossary prompt; the decoding with
   the fewest repeated words wins if it keeps at least half the content.
5. Language boundary guard: a chunk next to a chunk of the other language is cut at its longest pause and
   both halves are decoded with their own language detection; the split is kept when the halves come back
   in different languages without looping. Short German remarks inside English chunks stay German.
6. Clean-up: surviving repetitions collapse to one copy; known silence hallucinations
   ("Untertitel der Amara.org-Community", …) are dropped.
7. Missing-speech guard: detected speech with ≥ 3 s uncovered is re-decoded on its own (±0.5 s, own
   language detection) and accepted only where it adds words, does not loop and has avgLogProb ≥ -1.

Segments changed by a guard carry `repair` (`loopRedecoded`, `loopCollapsed`, `languageSplit`,
`gapRecovered`). A chunk whose first pass failed is marked `ChunkReport.failed`; when more than 5 % of
the decodable chunks failed and step 7 got no text back for them (always when all failed),
`transcribe` throws `decodingFailed` instead of returning a partial transcript.

## Cost

Apple silicon, large-v3-turbo, release build: about 17× real time (68 min lecture in 4.0 min), more with many
language switches (11 min clip with 12 switches: 12.5×). Peak memory about 1.3 GB for a 68 min recording,
most of it the audio load. First use downloads 1.5 GB and compiles Core ML for minutes; later loads take
about 0.5 s. `WhisperKitDecoder.unload()` frees the model; loading, decoding and unloading never
overlap (one at a time, in order). A model counts as downloaded once a finished download left its
`.download-complete` marker (or every compiled file is there); a folder that still fails to load
resumes the download once.

## Evaluation

`TranscribeBench` runs the real model. Its transcripts contain lecture text: write them under `.data/`.

```
swift build -c release --product TranscribeBench
B=Packages/Transcription/.build/release/TranscribeBench
$B prepare
F=.data/fixtures/<lecture>     # audio16k.wav and a transcript (git-ignored)
$B run --audio $F/audio16k.wav --strategy detect-de-en --pipeline engine --out .data/eval/x.json
$B run --audio $F/audio16k.wav --strategy detect-de-en --start 600 --end 840 --out .data/eval/y.json
$B langmap --audio $F/audio16k.wav --out .data/eval/langmap.json
$B langmap --audio $F/audio16k.wav --base .data/eval/langmap.json \
    --windows "300,900" --out .data/eval/langmap-v2.json     # re-judge single windows
$B analyze --audio $F/audio16k.wav --runs .data/eval/x.json \
    --srt $F/whisper.srt --reference-file .data/eval/langmap.json [--range 600-840]
```

`analyze --reference "de:0-60,en:60-240,…"` with exact spans also reports, per spoken-German
stretch, whether its text came out German, translated or missing.

The strategy decision: docs/decisions.md (2026-10-17, "Transcription default").
