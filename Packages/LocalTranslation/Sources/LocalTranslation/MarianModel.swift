import Foundation

/// One loaded OPUS-MT model: the source tokenizer, the vocabulary, the encoder and the merged
/// decoder (one graph with a past-key-values branch chosen by `use_cache_branch`). Translates
/// batches greedily with a key/value cache, as local-translate's CPU path does. Not `Sendable`:
/// it lives on `LocalTranslator`'s actor.
final class MarianModel {
    let repository: String
    private let sentencePiece: SentencePiece
    private let vocabulary: MarianVocabulary
    private let encoder: OnnxSession
    private let decoder: OnnxSession
    private let encoderTakesMask: Bool

    private let padID: Int
    private let eosID: Int
    private let decoderStartID: Int
    private let forcedEOSID: Int?
    private let badWords: [[Int]]
    private let maxPositions: Int

    private let layers: Int
    private let heads: Int
    private let headSize: Int
    /// `past_key_values.<layer>.<decoder|encoder>.<key|value>`, by layer.
    private let pastDecoderNames: [[String]]
    private let pastEncoderNames: [[String]]
    /// `present.<layer>.<decoder|encoder>.<key|value>`, by layer.
    private let presentDecoderNames: [[String]]
    private let presentEncoderNames: [[String]]

    /// Text → source ids (without EOS): the chunker counts a unit's tokens, then the batch
    /// encodes it again.
    private var memo: [String: [Int]] = [:]
    private static let memoLimit = 2_048

    /// Loads a ready repo folder (`TranslationModelStore.isReady`) on the CPU execution provider.
    init(folder: URL, repository: String, threads: Int) throws {
        self.repository = repository
        let config = try Self.readConfig(folder.appending(path: "config.json"), required: true)
        let generation: MarianConfig? = try? Self.readConfig(folder.appending(path: "generation_config.json"), required: false)
        guard let modelConfig = config else { throw TranslationError.modelUnreadable("\(repository): no config.json") }
        let merged = modelConfig.overridden(by: generation)

        let pad: Int = merged.padTokenID ?? 0
        let eos: Int = merged.eosTokenID ?? 0
        padID = pad
        eosID = eos
        decoderStartID = merged.decoderStartTokenID ?? pad
        forcedEOSID = merged.forcedEOSTokenID
        badWords = merged.badWordsIDs ?? []
        maxPositions = merged.maxPositionEmbeddings ?? merged.maxLength ?? 512

        let headCount: Int = modelConfig.decoderAttentionHeads ?? 8
        let width: Int = modelConfig.dModel ?? 512
        guard headCount > 0, width % headCount == 0 else { throw TranslationError.modelUnreadable("\(repository): bad head size") }
        heads = headCount
        headSize = width / headCount

        let spmData = try Self.read(folder.appending(path: "source.spm"), repository: repository)
        sentencePiece = try SentencePiece(spm: spmData)
        let vocabData = try Self.read(folder.appending(path: "vocab.json"), repository: repository)
        vocabulary = try MarianVocabulary(json: vocabData, eosID: eos, padID: pad)

        let encoderURL = folder.appending(path: TranslationModelStore.encoderFile)
        let decoderURL = folder.appending(path: TranslationModelStore.decoderFile)
        let encoderSession = try OnnxSession(modelAt: encoderURL, threads: threads)
        let decoderSession = try OnnxSession(modelAt: decoderURL, threads: threads)

        // The IO names, checked once.
        guard encoderSession.hasInput("input_ids"), encoderSession.hasOutput("last_hidden_state") else {
            throw TranslationError.modelUnreadable("\(repository): unexpected encoder")
        }
        var layerCount = 0
        while decoderSession.hasInput("past_key_values.\(layerCount).decoder.key") { layerCount += 1 }
        guard layerCount > 0 else { throw TranslationError.modelUnreadable("\(repository): the decoder has no cache inputs") }
        var pastDecoder: [[String]] = []
        var pastEncoder: [[String]] = []
        var presentDecoder: [[String]] = []
        var presentEncoder: [[String]] = []
        var requiredInputs: [String] = ["input_ids", "encoder_hidden_states", "encoder_attention_mask", "use_cache_branch"]
        var requiredOutputs: [String] = ["logits"]
        for layer in 0..<layerCount {
            let pastDecoderLayer: [String] = ["past_key_values.\(layer).decoder.key", "past_key_values.\(layer).decoder.value"]
            let pastEncoderLayer: [String] = ["past_key_values.\(layer).encoder.key", "past_key_values.\(layer).encoder.value"]
            let presentDecoderLayer: [String] = ["present.\(layer).decoder.key", "present.\(layer).decoder.value"]
            let presentEncoderLayer: [String] = ["present.\(layer).encoder.key", "present.\(layer).encoder.value"]
            pastDecoder.append(pastDecoderLayer)
            pastEncoder.append(pastEncoderLayer)
            presentDecoder.append(presentDecoderLayer)
            presentEncoder.append(presentEncoderLayer)
            requiredInputs.append(contentsOf: pastDecoderLayer)
            requiredInputs.append(contentsOf: pastEncoderLayer)
            requiredOutputs.append(contentsOf: presentDecoderLayer)
            requiredOutputs.append(contentsOf: presentEncoderLayer)
        }
        for name in requiredInputs where !decoderSession.hasInput(name) {
            throw TranslationError.modelUnreadable("\(repository): the decoder has no input \(name)")
        }
        for name in requiredOutputs where !decoderSession.hasOutput(name) {
            throw TranslationError.modelUnreadable("\(repository): the decoder has no output \(name)")
        }

        encoder = encoderSession
        decoder = decoderSession
        encoderTakesMask = encoderSession.hasInput("attention_mask")
        layers = layerCount
        pastDecoderNames = pastDecoder
        pastEncoderNames = pastEncoder
        presentDecoderNames = presentDecoder
        presentEncoderNames = presentEncoder
    }

    // MARK: Tokens

    /// Source text → model input ids (without EOS), like Python's `MarianTokenizer`.
    func sourceIDs(_ text: String) -> [Int] {
        if let known = memo[text] { return known }
        var ids: [Int] = []
        for piece in sentencePiece.encode(text) {
            if piece.isUnknown {
                ids.append(vocabulary.unknownID)
            } else {
                ids.append(vocabulary.id(of: piece.text) ?? vocabulary.unknownID)
            }
        }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[text] = ids
        return ids
    }

    /// A unit's tokens as the chunker counts them: the ids plus EOS.
    func countTokens(_ text: String) -> Int {
        sourceIDs(text).count + 1
    }

    // MARK: Generation

    /// Translates `texts` (one sentence each) in one batch. `targetToken` (">>xxx<<") goes in
    /// front of the source ids for models with several targets. An empty or punctuation-only
    /// result keeps the source text.
    func translate(_ texts: [String], targetToken: String?) throws -> [String] {
        guard !texts.isEmpty else { return [] }
        var languageID: Int?
        if let targetToken {
            guard let id = vocabulary.id(of: targetToken) else {
                throw TranslationError.modelUnreadable("\(repository) has no target token \(targetToken)")
            }
            languageID = id
        }

        // Rows: [token]? + source ids + EOS, right-padded; the mask covers the real tokens.
        let room: Int = languageID == nil ? maxPositions - 1 : maxPositions - 2
        var rows: [[Int]] = []
        var length = 0
        for text in texts {
            var row: [Int] = []
            if let languageID { row.append(languageID) }
            row.append(contentsOf: sourceIDs(text).prefix(max(0, room)))
            row.append(eosID)
            rows.append(row)
            length = max(length, row.count)
        }
        let batch: Int = rows.count
        let cells: Int = batch * length
        var inputIDs = [Int64](repeating: Int64(padID), count: cells)
        var mask = [Int64](repeating: 0, count: cells)
        for (rowIndex, row) in rows.enumerated() {
            let rowStart: Int = rowIndex * length
            for (column, id) in row.enumerated() {
                let cell: Int = rowStart + column
                inputIDs[cell] = Int64(id)
                mask[cell] = 1
            }
        }
        let idsTensor = try OnnxTensor(int64s: inputIDs, shape: [batch, length])
        let maskTensor = try OnnxTensor(int64s: mask, shape: [batch, length])

        // The encoder runs once.
        var encoderInputs: [String: OnnxTensor] = ["input_ids": idsTensor]
        if encoderTakesMask { encoderInputs["attention_mask"] = maskTensor }
        let encoded = try encoder.run(encoderInputs, outputs: ["last_hidden_state"])
        guard let hidden = encoded["last_hidden_state"] else { throw TranslationError.runtime("No encoder output") }

        // Marian has `maxPositions` positions; the decoder fails past them.
        let maxNewTokens: Int = min(500, length * 2 + 16)
        var finished = [Bool](repeating: false, count: batch)
        var generated = [[Int]](repeating: [], count: batch)
        var lastTokens = [Int](repeating: decoderStartID, count: batch)
        var decoderCache: [String: OnnxTensor] = [:]
        var encoderCache: [String: OnnxTensor] = [:]
        var decoderPresents: [String] = []
        var allPresents: [String] = []
        var allPasts: [String] = []
        for layer in 0..<layers {
            decoderPresents.append(contentsOf: presentDecoderNames[layer])
            allPresents.append(contentsOf: presentDecoderNames[layer])
            allPresents.append(contentsOf: presentEncoderNames[layer])
            allPasts.append(contentsOf: pastDecoderNames[layer])
            allPasts.append(contentsOf: pastEncoderNames[layer])
        }
        let emptyShape: [Int] = [batch, heads, 0, headSize]

        for step in 0..<maxNewTokens {
            try Task.checkCancellation()
            let tokens: [Int64] = lastTokens.map { Int64($0) }
            var inputs: [String: OnnxTensor] = [:]
            inputs["input_ids"] = try OnnxTensor(int64s: tokens, shape: [batch, 1])
            inputs["encoder_hidden_states"] = hidden
            inputs["encoder_attention_mask"] = maskTensor
            let usesCache: Bool = step > 0
            inputs["use_cache_branch"] = try OnnxTensor(bool: usesCache)
            var requested: [String] = ["logits"]
            if usesCache {
                for (name, tensor) in decoderCache { inputs[name] = tensor }
                for (name, tensor) in encoderCache { inputs[name] = tensor }
                requested.append(contentsOf: decoderPresents)
            } else {
                // Step 0: every past is empty ([B, heads, 0, head size]); ONNX Runtime allocates
                // no bytes for them.
                for name in allPasts {
                    inputs[name] = try OnnxTensor(emptyFloatsShape: emptyShape)
                }
                requested.append(contentsOf: allPresents)
            }

            let outputs = try decoder.run(inputs, outputs: requested)
            guard let logits = outputs["logits"] else { throw TranslationError.runtime("No logits") }
            for layer in 0..<layers {
                let pastNames: [String] = pastDecoderNames[layer]
                let presentNames: [String] = presentDecoderNames[layer]
                for index in 0..<2 {
                    guard let present = outputs[presentNames[index]] else { throw TranslationError.runtime("No decoder cache") }
                    decoderCache[pastNames[index]] = present
                }
                // The encoder's keys and values come from step 0 only: the cached branch returns
                // placeholders for them.
                if !usesCache {
                    let encoderPast: [String] = pastEncoderNames[layer]
                    let encoderPresent: [String] = presentEncoderNames[layer]
                    for index in 0..<2 {
                        guard let present = outputs[encoderPresent[index]] else { throw TranslationError.runtime("No encoder cache") }
                        encoderCache[encoderPast[index]] = present
                    }
                }
            }

            let forceEOS: Bool = step == maxNewTokens - 1
            let next = try nextTokens(logits, finished: finished, generated: generated, forceEOS: forceEOS)
            for row in 0..<batch {
                let token: Int = next[row]
                if !finished[row] {
                    generated[row].append(token)
                    if token == eosID { finished[row] = true }
                }
            }
            lastTokens = next
            if !finished.contains(false) { break }
        }

        var results: [String] = []
        for (row, text) in texts.enumerated() {
            let decoded = vocabulary.decode(generated[row])
            let cleaned = MarianOutput.clean(decoded, source: text)
            results.append(MarianOutput.looksBroken(cleaned) ? text : cleaned)
        }
        return results
    }

    /// The next token of every row: EOS for a finished row (sticky EOS) and at the last allowed
    /// step (`forced_eos_token_id`), else the argmax of the last position's logits without the
    /// `bad_words_ids` (the pad id is never generated). Ties keep the lower id.
    private func nextTokens(_ logits: OnnxTensor, finished: [Bool], generated: [[Int]], forceEOS: Bool) throws -> [Int] {
        let shape: [Int] = logits.shape
        guard shape.count == 3 else { throw TranslationError.runtime("Unexpected logits shape") }
        let rows: Int = shape[0]
        let positions: Int = shape[1]
        let vocab: Int = shape[2]
        guard rows == finished.count, positions > 0, vocab > 0 else { throw TranslationError.runtime("Unexpected logits shape") }
        let forced: Int = forcedEOSID ?? eosID
        var tokens: [Int] = []
        tokens.reserveCapacity(rows)
        try logits.withFloats { values in
            let expected: Int = rows * positions * vocab
            guard values.count == expected else { throw TranslationError.runtime("Unexpected logits size") }
            for row in 0..<rows {
                if finished[row] {
                    tokens.append(eosID)
                    continue
                }
                if forceEOS {
                    tokens.append(forced)
                    continue
                }
                let banned: [Int] = bannedTokens(after: generated[row])
                let rowOffset: Int = row * positions
                let lastPosition: Int = rowOffset + positions - 1
                let start: Int = lastPosition * vocab
                var best = -1
                var bestValue = -Float.infinity
                for token in 0..<vocab {
                    let value: Float = values[start + token]
                    if value > bestValue, !banned.contains(token) {
                        best = token
                        bestValue = value
                    }
                }
                tokens.append(best >= 0 ? best : eosID)
            }
        }
        return tokens
    }

    /// Tokens `bad_words_ids` forbids next: single-token entries always, longer ones when the
    /// row ends with their prefix.
    private func bannedTokens(after generated: [Int]) -> [Int] {
        var banned: [Int] = []
        for sequence in badWords {
            guard let last = sequence.last else { continue }
            let prefix = sequence.dropLast()
            if prefix.isEmpty {
                banned.append(last)
            } else if generated.count >= prefix.count, Array(generated.suffix(prefix.count)) == Array(prefix) {
                banned.append(last)
            }
        }
        return banned
    }

    // MARK: Files

    private static func read(_ url: URL, repository: String) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TranslationError.modelUnreadable("\(repository): \(url.lastPathComponent) unreadable")
        }
    }

    private static func readConfig(_ url: URL, required: Bool) throws -> MarianConfig? {
        guard let data = try? Data(contentsOf: url) else {
            if required { throw TranslationError.modelUnreadable("\(url.lastPathComponent) missing") }
            return nil
        }
        do {
            return try JSONDecoder().decode(MarianConfig.self, from: data)
        } catch {
            throw TranslationError.modelUnreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
