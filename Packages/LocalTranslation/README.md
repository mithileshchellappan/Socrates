# LocalTranslation

Mail's Translate on the device with the same OPUS-MT (MarianMT) models that the author's local-translate browser extension runs on its CPU path: `Xenova/opus-mt-<src>-<tgt>`, q8 ONNX graphs, natively in Swift. No Apple Translation, no Claude, no network after a pair's one-time download. Decision: docs/decisions.md, 2026-10-20 "Mail Translate on device". Logic only: no StudyCore, no UI. Used by MailUI.

No automated test suite at present; verified by building, and translation is checked live.

## Public surface

```swift
public enum TranslationEvent: Sendable {
    case downloading(fraction: Double)            // the route's missing models, 0…1, never backwards
    case translated(index: Int, text: String)     // texts[index] in full, in index order
}

public actor LocalTranslator {
    public static let shared: LocalTranslator     // TranslationModelStore.shared
    public init(store: TranslationModelStore, idleUnload: Duration = .seconds(120))
    public nonisolated static func canTranslate(from source: String, to target: String) -> Bool
    public nonisolated func translations(of texts: [String], from source: String, to target: String)
        -> AsyncThrowingStream<TranslationEvent, any Error>
    public func unload()
}

public enum TranslationRoutes {                   // languages.js, tables verbatim
    public static func normalize(_ code: String?) -> String
    public static func plan(from: String, to: String) -> TranslationRoute?   // nil: unsupported; no steps: same language
    public static let spaceless: Set<String>
}

public struct TranslationModelStore: Sendable {
    public static let shared: TranslationModelStore
    public func isReady(_ repository: String) -> Bool          // no network
    public func download(_ repository: String, progress: @Sendable (Int64, Int64) -> Void) async throws
    public func invalidate(_ repository: String)               // the next download re-verifies it
    public func remove(_ repository: String) throws
    public func removeAll() throws
    public func installed() -> [InstalledTranslationModel]
}

public enum TranslationError: Error { case unsupportedPair, notEnoughSpace, downloadFailed(String), modelUnreadable(String), runtime(String) }
```

Language codes are what `Locale.Language.minimalIdentifier` gives ("de", "en", "zh-Hant"); `normalize` maps them to the route codes (`nb` → `no`, `zh-Hant` → `zh-TW`, …).

## How a translation runs

1. Plan the route: a direct pair model, else source → en, then en → target (multi-target models get a `>>xxx<<` token id in front of the source ids). Any language into English has a route (`mul-en` as the rough fallback).
2. Download every repo of the route that is not ready (`.downloading` events once bytes are on their way; two jobs share one download; a cancelled job stops waiting, the download goes on).
3. Load the route (one route resident; a model ONNX Runtime cannot open is invalidated and reported as `modelUnreadable`; the next job checks its files against `manifest.json` offline and fetches only those that fail). Unloading asks the allocator to return the freed pages (`malloc_zone_pressure_relief`).
4. Chunk each text into sentences (`TextChunker`, a port of `chunker.js` on `NLTokenizer`): at most 120 tokens a unit, clause then word splits beyond that, letterless units, bare URLs and addresses passed through; each unit keeps the whitespace after it. Two departures from `chunker.js`: a German ordinal does not end a sentence (a day before a month's name, "16. Februar"; a number after an article or preposition, "im 3. Semester"), and a link or mail address inside a sentence is a unit of its own, passed through, with the text on either side translated (the model translated a URL's words).
5. Translate the units not in the cache in batches of 1, 2, 4, 4…, each batch through every step: the encoder once; the merged decoder at step 0 with empty pasts ([B, 8, 0, 64]) and `use_cache_branch = false`, after that with the decoder presents plus the step-0 encoder presents and `use_cache_branch = true`; greedy argmax without `bad_words_ids`, sticky EOS, forced EOS at `min(500, 2L+16)` new tokens; `Task.checkCancellation()` every step. Decode through `vocab.json` (Metaspace, `clean_up_tokenization`), then `cleanOutput`; an empty or punctuation-only result keeps the source.
6. Yield each text once all its units are back, in order.

## On disk

```
~/Library/Application Support/Socrates/Models/Translation/      (excluded from backups)
  Xenova/opus-mt-de-en/
    config.json  generation_config.json  vocab.json  source.spm
    onnx/encoder_model_quantized.onnx  onnx/decoder_model_merged_quantized.onnx
    manifest.json   (revision; per file path, size, sha256 or git blob oid)
    .complete       (written last)
```

Like `WhisperModelStore`, the folder ignores `SOCRATES_DATA_ROOT`: models are a shared, re-downloadable cache. Downloads stream from `https://huggingface.co/<repo>/resolve/<revision>/<path>` into `<path>.partial` (resumed with `Range`), verify (SHA-256 for LFS files, git blob SHA-1 for small ones, size for all), retry transient failures after 1, 2, 4 and 8 s, and need the bytes still missing plus 50 MB free (verified files and resumable `.partial` bytes do not count; `.partial` files that cannot resume are removed on the next attempt). A repo whose manifest lists every file's size and hash is re-checked from it offline; the file list is fetched only without one (or when it follows `main`). de-en and en-de are pinned to the revisions in the plan (§3.2); other repos follow `main`. Nothing in the app removes models yet (`remove`/`removeAll` exist).

## Runtime

ONNX Runtime 1.24.2: the C/C++ pod archive the official Swift package pins (`binaryTarget` `onnxruntime`, static xcframework for macOS, iOS and the iOS Simulator). `COnnxRuntime` is a small C shim (sessions, float / int64 / bool tensors, run by input and output index, `char *` errors): the Objective-C binding has no bool tensor type, and the merged decoder's `use_cache_branch` is a bool. CPU execution provider (MLAS), 4 intra-op threads, 1 inter-op thread, sequential, every graph optimization. The q8 graphs are dynamic-quantized, which Core ML does not take, so the Core ML provider is linked (it is in the static library) but not used. Logs: `os.Logger` subsystem the app's bundle ID, category `translation`.

## Attribution

- **OPUS-MT** models by Helsinki-NLP (Jörg Tiedemann and the OPUS-MT team), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **ONNX conversions** by Xenova (Joshua Lochner) for Transformers.js (`Xenova/opus-mt-*`), and `onnx-community/opus-mt-en-trk-ONNX`.
- **ONNX Runtime** by Microsoft, MIT License.
- The engine's behaviour (tokenizer, chunker, routes, decoding) is ported from the author's local-translate browser extension.
