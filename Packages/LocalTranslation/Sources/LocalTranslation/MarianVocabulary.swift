import Foundation

/// The values of a Marian repo's `config.json` and `generation_config.json` the engine uses.
struct MarianConfig: Decodable, Sendable {
    var padTokenID: Int?
    var eosTokenID: Int?
    var decoderStartTokenID: Int?
    var forcedEOSTokenID: Int?
    var badWordsIDs: [[Int]]?
    var maxLength: Int?
    var maxPositionEmbeddings: Int?
    var decoderAttentionHeads: Int?
    var dModel: Int?

    enum CodingKeys: String, CodingKey {
        case padTokenID = "pad_token_id"
        case eosTokenID = "eos_token_id"
        case decoderStartTokenID = "decoder_start_token_id"
        case forcedEOSTokenID = "forced_eos_token_id"
        case badWordsIDs = "bad_words_ids"
        case maxLength = "max_length"
        case maxPositionEmbeddings = "max_position_embeddings"
        case decoderAttentionHeads = "decoder_attention_heads"
        case dModel = "d_model"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        padTokenID = Self.int(container, .padTokenID)
        eosTokenID = Self.int(container, .eosTokenID)
        decoderStartTokenID = Self.int(container, .decoderStartTokenID)
        forcedEOSTokenID = Self.int(container, .forcedEOSTokenID)
        badWordsIDs = try? container.decodeIfPresent([[Int]].self, forKey: .badWordsIDs)
        maxLength = Self.int(container, .maxLength)
        maxPositionEmbeddings = Self.int(container, .maxPositionEmbeddings)
        decoderAttentionHeads = Self.int(container, .decoderAttentionHeads)
        dModel = Self.int(container, .dModel)
    }

    /// An id given as a number, or the first of a list (`eos_token_id` may be either).
    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let values = try? container.decodeIfPresent([Int].self, forKey: key) { return values.first }
        return nil
    }

    /// The generation config's values over the model config's.
    func overridden(by generation: MarianConfig?) -> MarianConfig {
        guard let generation else { return self }
        var merged = self
        if let value = generation.padTokenID { merged.padTokenID = value }
        if let value = generation.eosTokenID { merged.eosTokenID = value }
        if let value = generation.decoderStartTokenID { merged.decoderStartTokenID = value }
        if let value = generation.forcedEOSTokenID { merged.forcedEOSTokenID = value }
        if let value = generation.badWordsIDs { merged.badWordsIDs = value }
        if let value = generation.maxLength { merged.maxLength = value }
        return merged
    }
}

/// `vocab.json` both ways (Marian's source and target share it), the special ids, and the
/// decoding of target ids back to text.
struct MarianVocabulary: Sendable {
    private let ids: [String: Int]
    private let pieces: [String?]
    /// Ids decoding skips: `</s>`, `<unk>`, `<pad>` and every `>>xxx<<` target token.
    private let skipped: Set<Int>
    let unknownID: Int

    init(json: Data, eosID: Int, padID: Int) throws {
        let ids: [String: Int]
        do {
            ids = try JSONDecoder().decode([String: Int].self, from: json)
        } catch {
            throw TranslationError.modelUnreadable("vocab.json: \(error.localizedDescription)")
        }
        var largest = 0
        for id in ids.values where id > largest { largest = id }
        var pieces = [String?](repeating: nil, count: largest + 1)
        var skipped: Set<Int> = [eosID, padID]
        for (piece, id) in ids where id >= 0 {
            pieces[id] = piece
            if piece.hasPrefix(">>"), piece.hasSuffix("<<"), piece.count > 4 { skipped.insert(id) }
        }
        let unknownID = ids["<unk>"] ?? 1
        skipped.insert(unknownID)
        self.ids = ids
        self.pieces = pieces
        self.skipped = skipped
        self.unknownID = unknownID
    }

    func id(of piece: String) -> Int? {
        ids[piece]
    }

    /// Target ids to text: special ids dropped, pieces joined, "▁" as spaces, one leading space
    /// dropped (Metaspace), then `clean_up_tokenization`.
    func decode(_ tokenIDs: [Int]) -> String {
        var joined = ""
        for id in tokenIDs {
            if skipped.contains(id) { continue }
            guard id >= 0, id < pieces.count, let piece = pieces[id] else { continue }
            joined.append(piece)
        }
        var text = joined.replacingOccurrences(of: "\u{2581}", with: " ")
        if text.hasPrefix(" ") { text.removeFirst() }
        return Self.cleanUpTokenization(text)
    }

    /// Transformers' `clean_up_tokenization`.
    static func cleanUpTokenization(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " ' ", with: "'")
        result = result.replacingOccurrences(of: " n't", with: "n't")
        result = result.replacingOccurrences(of: " 'm", with: "'m")
        result = result.replacingOccurrences(of: " 's", with: "'s")
        result = result.replacingOccurrences(of: " 've", with: "'ve")
        result = result.replacingOccurrences(of: " 're", with: "'re")
        return result
    }
}

/// local-translate's `cleanOutput` and `looksBroken`: Marian occasionally loops ("so, uh, so, uh,
/// …"). Only degenerate repetition the source does not have collapses: a run of 8 or more of the
/// same punctuation mark, or a group with letters repeated 6 or more times.
enum MarianOutput {
    private static let punctuationRun: NSRegularExpression? = try? NSRegularExpression(pattern: "([.…?!,·])\\1{7,}")
    private static let repeatedGroup: NSRegularExpression? = try? NSRegularExpression(pattern: "(.{3,40}?)(?:\\s*\\1){5,}")
    private static let brokenOutput: NSRegularExpression? = try? NSRegularExpression(pattern: "^[\\s.…?!,·-]+$")

    static func clean(_ text: String, source: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let punctuationRun {
            result = replace(punctuationRun, in: result) { match, group in
                source.contains(match) ? match : group
            }
        }
        if let repeatedGroup {
            result = replace(repeatedGroup, in: result) { match, group in
                guard hasLetter(group), !source.contains(match) else { return match }
                return group
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Empty, or only spaces and punctuation.
    static func looksBroken(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let brokenOutput else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return brokenOutput.firstMatch(in: text, range: range) != nil
    }

    static func hasLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { isLetter($0) }
    }

    /// `\p{L}`.
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// Every match of `regex` replaced by `transform(match, group 1)`, left to right (a global
    /// `String.replace` with a function).
    static func replace(_ regex: NSRegularExpression, in text: String, _ transform: (String, String) -> String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = 0
        for match in matches {
            let start: Int = match.range.location
            let gap = NSRange(location: last, length: start - last)
            result.append(ns.substring(with: gap))
            let whole = ns.substring(with: match.range)
            let groupRange = match.range(at: 1)
            let group = groupRange.location == NSNotFound ? "" : ns.substring(with: groupRange)
            result.append(transform(whole, group))
            last = start + match.range.length
        }
        result.append(ns.substring(from: last))
        return result
    }
}
