import Foundation
@preconcurrency import WhisperKit

/// Forwards to WhisperKit's tokenizer but reports only some languages as language tokens.
///
/// WhisperKit's language detection masks every logit that is not in `allLanguageTokens` and
/// takes the argmax, so restricting the set to {de, en} makes per-window detection pick the more
/// likely of German and English instead of, say, Dutch on a noisy chunk.
struct LanguageRestrictedTokenizer: WhisperTokenizer {
    let base: any WhisperTokenizer
    let allLanguageTokens: Set<Int>
    let languages: [String]

    /// Returns nil when none of `languages` is a language token of `base`.
    init?(base: any WhisperTokenizer, languages: [String]) {
        let tokens = languages.compactMap { base.convertTokenToId("<|\($0)|>") }
            .filter { base.allLanguageTokens.contains($0) }
        guard !tokens.isEmpty else { return nil }
        self.base = base
        self.allLanguageTokens = Set(tokens)
        self.languages = languages
    }

    var specialTokens: SpecialTokens { base.specialTokens }
    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
    }
}
