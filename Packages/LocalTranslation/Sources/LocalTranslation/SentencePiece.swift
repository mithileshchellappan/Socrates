import Foundation

/// A SentencePiece (Unigram) encoder over a Marian model's own `source.spm`: a port of
/// local-translate's `sentencepiece.js`, over Unicode scalars instead of UTF-16 units.
///
/// Why not `tokenizer.json`: the converted tokenizers segment words differently from the model's
/// `source.spm` (Dutch "zonnig" → `zo|nnig` instead of `▁zon|nig`), the model then sees sequences
/// it never trained on, and translations fall apart. This does what Python's `MarianTokenizer`
/// does: segment with the source model, then the caller maps pieces to ids in the shared vocab.
struct SentencePiece: Sendable {
    struct Piece: Hashable, Sendable {
        var text: String
        var isUnknown: Bool
    }

    /// "▁", the word-boundary marker.
    static let whitespace: Unicode.Scalar = "\u{2581}"
    /// sentencepiece's `kUnkPenalty`.
    static let unknownPenalty: Double = 10

    // Piece types (sentencepiece_model.proto).
    private static let normalType: UInt64 = 1
    private static let unknownType: UInt64 = 2
    private static let controlType: UInt64 = 3
    private static let userDefinedType: UInt64 = 4
    private static let unusedType: UInt64 = 5

    private let scores: [String: Double]
    /// The longest piece, in scalars.
    private let maxLength: Int
    private let unknownScore: Double
    private let addDummyPrefix: Bool
    private let removeExtraWhitespace: Bool

    /// The number of pieces the encoder can produce.
    var count: Int { scores.count }

    init(spm: Data) throws {
        let bytes = [UInt8](spm)
        let model = try ProtoReader.fields(of: bytes, in: 0..<bytes.count)
        var scores: [String: Double] = [:]
        var minScore = Double.infinity
        var maxLength = 1
        for value in model[1] ?? [] {
            guard case .bytes(let range) = value else { continue }
            let piece = try ProtoReader.fields(of: bytes, in: range)
            var text = ""
            if case .bytes(let textRange)? = piece[1]?.first {
                text = String(decoding: bytes[textRange], as: UTF8.self)
            }
            var score: Double = 0
            if case .fixed32(let bits)? = piece[2]?.first {
                score = Double(Float(bitPattern: bits))
            }
            var type = Self.normalType
            if case .varint(let raw)? = piece[3]?.first {
                type = raw
            }
            if type == Self.controlType || type == Self.unknownType || type == Self.unusedType { continue }
            scores[text] = type == Self.userDefinedType ? 0 : score
            if type == Self.normalType { minScore = min(minScore, score) }
            maxLength = max(maxLength, text.unicodeScalars.count)
        }
        guard !scores.isEmpty else { throw TranslationError.modelUnreadable("source.spm has no pieces") }

        // normalizer_spec (field 3): add_dummy_prefix 3, remove_extra_whitespaces 4 (default true).
        var addDummyPrefix = true
        var removeExtraWhitespace = true
        if case .bytes(let range)? = model[3]?.first {
            let normalizer = try ProtoReader.fields(of: bytes, in: range)
            if case .varint(let flag)? = normalizer[3]?.first { addDummyPrefix = flag != 0 }
            if case .varint(let flag)? = normalizer[4]?.first { removeExtraWhitespace = flag != 0 }
        }

        self.scores = scores
        self.maxLength = maxLength
        self.unknownScore = minScore - Self.unknownPenalty
        self.addDummyPrefix = addDummyPrefix
        self.removeExtraWhitespace = removeExtraWhitespace
    }

    /// Approximates the `nmt_nfkc` normalizer: NFKC, controls dropped, whitespace unified, the
    /// dummy prefix, then spaces as "▁".
    func normalized(_ text: String) -> [Unicode.Scalar] {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(nfkc.unicodeScalars.count + 1)
        for scalar in nfkc.unicodeScalars {
            if Self.isDropped(scalar) { continue }
            if Self.isWhitespace(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        if removeExtraWhitespace {
            var collapsed: [Unicode.Scalar] = []
            collapsed.reserveCapacity(scalars.count)
            for scalar in scalars {
                if scalar == " ", collapsed.last == " " { continue }
                collapsed.append(scalar)
            }
            while collapsed.first == " " { collapsed.removeFirst() }
            while collapsed.last == " " { collapsed.removeLast() }
            scalars = collapsed
        }
        guard !scalars.isEmpty else { return [] }
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count + 1)
        if addDummyPrefix { result.append(Self.whitespace) }
        for scalar in scalars {
            result.append(scalar == " " ? Self.whitespace : scalar)
        }
        return result
    }

    /// Viterbi segmentation over scalars. A piece wins a position only with a strictly higher
    /// score (local-translate's order, so ties match); a scalar no piece starts with becomes a
    /// one-scalar unknown piece, and runs of unknown pieces merge into one.
    func encode(_ text: String) -> [Piece] {
        let s = normalized(text)
        let n = s.count
        guard n > 0 else { return [] }
        var best = [Double](repeating: -Double.infinity, count: n + 1)
        var from = [Int](repeating: -1, count: n + 1)
        var isUnknown = [Bool](repeating: false, count: n + 1)
        best[0] = 0
        for i in 0..<n {
            let start: Double = best[i]
            if start == -Double.infinity { continue }
            var matched = false
            let limit: Int = min(n, i + maxLength)
            var key = String.UnicodeScalarView()
            for j in (i + 1)...limit {
                key.append(s[j - 1])
                guard let score = scores[String(key)] else { continue }
                if j == i + 1 { matched = true }
                let value: Double = start + score
                if value > best[j] {
                    best[j] = value
                    from[j] = i
                    isUnknown[j] = false
                }
            }
            if !matched {
                let j = i + 1
                let value: Double = start + unknownScore
                if value > best[j] {
                    best[j] = value
                    from[j] = i
                    isUnknown[j] = true
                }
            }
        }

        var pieces: [Piece] = []
        var end = n
        while end > 0 {
            let begin = from[end]
            guard begin >= 0, begin < end else { break }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: s[begin..<end])
            pieces.append(Piece(text: String(view), isUnknown: isUnknown[end]))
            end = begin
        }
        pieces.reverse()

        var merged: [Piece] = []
        merged.reserveCapacity(pieces.count)
        for piece in pieces {
            if piece.isUnknown, let last = merged.last, last.isUnknown {
                merged[merged.count - 1].text.append(piece.text)
            } else {
                merged.append(piece)
            }
        }
        return merged
    }

    /// U+0000–0008, 000B, 000E–001F, 007F, 200B and FEFF.
    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value <= 0x08 { return true }
        if value == 0x0B { return true }
        if value >= 0x0E, value <= 0x1F { return true }
        return value == 0x7F || value == 0x200B || value == 0xFEFF
    }

    /// JavaScript's `\s`: tab, line feed, vertical tab, form feed, carriage return, U+2028,
    /// U+2029, U+FEFF and every space separator (Zs).
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x09, value <= 0x0D { return true }
        if value == 0x2028 || value == 0x2029 || value == 0xFEFF { return true }
        return scalar.properties.generalCategory == .spaceSeparator
    }
}

/// A protobuf message read into field number → values (only the wire types SentencePiece uses).
enum ProtoReader {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Range<Int>)
        case fixed32(UInt32)
    }

    static func fields(of bytes: [UInt8], in range: Range<Int>) throws -> [Int: [Value]] {
        var fields: [Int: [Value]] = [:]
        var position = range.lowerBound
        let end = range.upperBound
        guard end <= bytes.count else { throw TranslationError.modelUnreadable("source.spm is truncated") }
        while position < end {
            let key = try varint(bytes, &position, end: end)
            let field = Int(key >> 3)
            let wire = key & 7
            let value: Value
            switch wire {
            case 0:
                value = .varint(try varint(bytes, &position, end: end))
            case 1:
                guard end - position >= 8 else { throw TranslationError.modelUnreadable("source.spm is truncated") }
                var bits: UInt64 = 0
                for offset in 0..<8 {
                    let byte = UInt64(bytes[position + offset])
                    bits |= byte << UInt64(8 * offset)
                }
                position += 8
                value = .fixed64(bits)
            case 2:
                let length = try varint(bytes, &position, end: end)
                guard length <= UInt64(end - position) else { throw TranslationError.modelUnreadable("source.spm is truncated") }
                let upper = position + Int(length)
                value = .bytes(position..<upper)
                position = upper
            case 5:
                guard end - position >= 4 else { throw TranslationError.modelUnreadable("source.spm is truncated") }
                var bits: UInt32 = 0
                for offset in 0..<4 {
                    let byte = UInt32(bytes[position + offset])
                    bits |= byte << UInt32(8 * offset)
                }
                position += 4
                value = .fixed32(bits)
            default:
                throw TranslationError.modelUnreadable("source.spm uses wire type \(wire)")
            }
            fields[field, default: []].append(value)
        }
        return fields
    }

    private static func varint(_ bytes: [UInt8], _ position: inout Int, end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end else { throw TranslationError.modelUnreadable("source.spm is truncated") }
            let byte = bytes[position]
            position += 1
            if shift < 64 {
                let low = UInt64(byte & 0x7F)
                result |= low << shift
            }
            if byte < 0x80 { return result }
            shift += 7
        }
    }
}
