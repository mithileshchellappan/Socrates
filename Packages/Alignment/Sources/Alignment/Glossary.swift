import Foundation

/// Course vocabulary whose terms weigh more when matching speech to slides (`Course.glossary`).
///
/// The boost multiplies a term's IDF (``AlignmentParameters/glossaryBoost``). Terms are tokenized with the
/// same rules as slides and transcript, so "Hypervisors" and "hypervisor" are the same entry.
public struct Glossary: Hashable, Sendable {
    /// Extra per-term weights (multiplied with the global boost), keyed by raw entry text.
    public var weights: [String: Double]

    public init(weights: [String: Double] = [:]) {
        self.weights = weights
    }

    /// Entries separated by newlines, commas or semicolons, each with weight 1.
    public init(text: String) {
        var weights: [String: Double] = [:]
        for entry in text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" }) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { weights[trimmed] = 1 }
        }
        self.weights = weights
    }

    public init(terms: [String]) {
        self.weights = Dictionary(terms.map { ($0, 1.0) }, uniquingKeysWith: max)
    }

    public static let empty = Glossary()

    public var isEmpty: Bool { weights.isEmpty }

    /// Term → IDF multiplier after tokenization. Multi-word entries boost each of their terms.
    func termMultipliers(tokenizer: Tokenizer, boost: Double) -> [String: Double] {
        var result: [String: Double] = [:]
        for (entry, weight) in weights {
            for term in tokenizer.terms(in: entry) {
                result[term] = max(result[term] ?? 1, 1 + (boost - 1) * weight)
            }
        }
        return result
    }
}
