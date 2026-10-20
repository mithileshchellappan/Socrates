import Foundation

/// One model of a route: `repository` translates `source` → `target`, with `targetToken` (">>xxx<<")
/// in front of the source ids when the model has several targets.
public struct TranslationStep: Hashable, Sendable {
    public var repository: String
    public var targetToken: String?
    public var source: String
    public var target: String
    /// A general multilingual model (`mul`): rough output.
    public var isLowQuality: Bool
}

/// The model chain for a language pair: one step, or two through English.
public struct TranslationRoute: Hashable, Sendable {
    public var steps: [TranslationStep]

    public var isLowQuality: Bool {
        steps.contains { $0.isLowQuality }
    }

    /// Identifies the models and tokens (the unit cache's key prefix).
    public var id: String {
        var parts: [String] = []
        for step in steps {
            let token = step.targetToken ?? ""
            parts.append("\(step.repository)|\(token)")
        }
        return parts.joined(separator: ">")
    }
}

/// local-translate's `languages.js`: the language codes and the OPUS-MT model routes, tables
/// copied verbatim. Routing for source → target: a direct pair model (e.g. de→fr), else through
/// English (source → en, then en → target). Multi-target models need a ">>xxx<<" target token.
public enum TranslationRoutes {
    /// Direct models into English (source → en). jap-en is Bible-only, so ja uses ja-en.
    static let toEnglish: [String: String] = [
        "af": "Xenova/opus-mt-af-en", "ar": "Xenova/opus-mt-ar-en", "cs": "Xenova/opus-mt-cs-en",
        "da": "Xenova/opus-mt-da-en", "de": "Xenova/opus-mt-de-en", "es": "Xenova/opus-mt-es-en",
        "et": "Xenova/opus-mt-et-en", "fi": "Xenova/opus-mt-fi-en", "fr": "Xenova/opus-mt-fr-en",
        "hi": "Xenova/opus-mt-hi-en", "hu": "Xenova/opus-mt-hu-en", "id": "Xenova/opus-mt-id-en",
        "it": "Xenova/opus-mt-it-en", "ja": "Xenova/opus-mt-ja-en", "ko": "Xenova/opus-mt-ko-en",
        "nl": "Xenova/opus-mt-nl-en", "pl": "Xenova/opus-mt-pl-en", "ru": "Xenova/opus-mt-ru-en",
        "sv": "Xenova/opus-mt-sv-en", "th": "Xenova/opus-mt-th-en", "tr": "Xenova/opus-mt-tr-en",
        "uk": "Xenova/opus-mt-uk-en", "vi": "Xenova/opus-mt-vi-en", "xh": "Xenova/opus-mt-xh-en",
        "zh": "Xenova/opus-mt-zh-en", "zh-TW": "Xenova/opus-mt-zh-en",
    ]

    /// Language-family models into English.
    static let romance: [String] = ["pt", "ro", "ca", "gl", "oc", "la", "co", "an", "wa", "rm", "sc", "lad"]
    static let baltic: [String] = ["lv", "lt"]
    static let romanceToEnglish = "Xenova/opus-mt-ROMANCE-en"
    static let balticToEnglish = "Xenova/opus-mt-bat-en"
    static let multilingualToEnglish = "Xenova/opus-mt-mul-en"
    static let englishToMultilingual = "Xenova/opus-mt-en-mul"
    static let englishToTurkic = "onnx-community/opus-mt-en-trk-ONNX"

    /// Models out of English (en → target).
    static let fromEnglishModels: [String: String] = [
        "af": "Xenova/opus-mt-en-af", "cs": "Xenova/opus-mt-en-cs", "da": "Xenova/opus-mt-en-da",
        "de": "Xenova/opus-mt-en-de", "es": "Xenova/opus-mt-en-es", "fi": "Xenova/opus-mt-en-fi",
        "fr": "Xenova/opus-mt-en-fr", "hi": "Xenova/opus-mt-en-hi", "hu": "Xenova/opus-mt-en-hu",
        "id": "Xenova/opus-mt-en-id", "it": "Xenova/opus-mt-en-it", "nl": "Xenova/opus-mt-en-nl",
        "ro": "Xenova/opus-mt-en-ro", "ru": "Xenova/opus-mt-en-ru", "sv": "Xenova/opus-mt-en-sv",
        "uk": "Xenova/opus-mt-en-uk", "xh": "Xenova/opus-mt-en-xh",
        "ar": "Xenova/opus-mt-en-ar",
        "vi": "Xenova/opus-mt-en-vi",
        "zh": "Xenova/opus-mt-en-zh",
        "zh-TW": "Xenova/opus-mt-en-zh",
        "pt": "Xenova/opus-mt-en-ROMANCE",
        "ca": "Xenova/opus-mt-en-ROMANCE",
        "gl": "Xenova/opus-mt-en-ROMANCE",
        "oc": "Xenova/opus-mt-en-ROMANCE",
        "la": "Xenova/opus-mt-en-ROMANCE",
        // Germanic multi-target model: clean output, better than the general en-mul.
        "no": "Xenova/opus-mt-gem-gem",
        "is": "Xenova/opus-mt-gem-gem",
        "fo": "Xenova/opus-mt-gem-gem",
        "lb": "Xenova/opus-mt-gem-gem",
        "fy": "Xenova/opus-mt-gem-gem",
        "yi": "Xenova/opus-mt-gem-gem",
        "tr": "onnx-community/opus-mt-en-trk-ONNX",
        "az": "onnx-community/opus-mt-en-trk-ONNX",
        "kk": "onnx-community/opus-mt-en-trk-ONNX",
        "uz": "onnx-community/opus-mt-en-trk-ONNX",
        "ky": "onnx-community/opus-mt-en-trk-ONNX",
        "tt": "onnx-community/opus-mt-en-trk-ONNX",
        "tk": "onnx-community/opus-mt-en-trk-ONNX",
    ]

    /// The target tokens of `fromEnglishModels` that need one.
    static let fromEnglishTokens: [String: String] = [
        "ar": ">>ara<<",
        "vi": ">>vie<<",
        "zh": ">>cmn_Hans<<",
        "zh-TW": ">>cmn_Hant<<",
        "pt": ">>pt<<",
        "ca": ">>ca<<",
        "gl": ">>gl<<",
        "oc": ">>oc<<",
        "la": ">>la<<",
        "no": ">>nob<<",
        "is": ">>isl<<",
        "fo": ">>fao<<",
        "lb": ">>ltz<<",
        "fy": ">>fry<<",
        "yi": ">>yid<<",
        "tr": ">>tur<<",
        "az": ">>aze_Latn<<",
        "kk": ">>kaz_Cyrl<<",
        "uz": ">>uzb_Latn<<",
        "ky": ">>kir_Cyrl<<",
        "tt": ">>tat<<",
        "tk": ">>tuk_Latn<<",
    ]

    /// Long tail via the multilingual en→mul model (lower quality): language → token name.
    static let englishToMultilingualTokens: [String: String] = [
        "ja": "jpn", "el": "ell", "he": "heb", "pl": "pol", "bg": "bul", "lt": "lit", "lv": "lav",
        "et": "est", "sl": "slv", "hr": "hrv", "sr": "srp_Cyrl", "bs": "bos_Latn", "mk": "mkd",
        "sq": "sqi", "hy": "hye", "ka": "kat", "fa": "pes", "ur": "urd", "bn": "ben", "ta": "tam",
        "te": "tel", "mr": "mar", "gu": "guj", "kn": "kan", "ml": "mal", "pa": "pan_Guru", "th": "tha",
        "km": "khm", "lo": "lao", "my": "mya", "ms": "zlm_Latn", "is": "isl", "ga": "gle", "cy": "cym",
        "eu": "eus", "eo": "epo", "be": "bel", "mn": "mon", "si": "sin", "am": "amh", "yo": "yor",
        "zu": "zul", "ig": "ibo", "jv": "jav", "su": "sun", "no": "nob", "mt": "mlt", "lb": "ltz",
        "fy": "fry", "yi": "yid", "ps": "pus", "ku": "kur_Latn", "tg": "tgk_Cyrl", "ug": "uig_Arab",
        "so": "som", "mg": "mlg", "ht": "hat", "sn": "sna", "ny": "nya", "ceb": "ceb", "haw": "haw",
        "sm": "smo", "mi": "mri", "gd": "gla", "br": "bre", "fo": "fao",
    ]

    /// Direct non-English pairs: avoids a lossy English pivot.
    static let direct: [String: String] = [
        "da-de": "Xenova/opus-mt-da-de", "de-es": "Xenova/opus-mt-de-es", "de-fr": "Xenova/opus-mt-de-fr",
        "es-de": "Xenova/opus-mt-es-de", "es-fr": "Xenova/opus-mt-es-fr", "es-it": "Xenova/opus-mt-es-it",
        "es-ru": "Xenova/opus-mt-es-ru", "fi-de": "Xenova/opus-mt-fi-de", "fr-de": "Xenova/opus-mt-fr-de",
        "fr-es": "Xenova/opus-mt-fr-es", "fr-ro": "Xenova/opus-mt-fr-ro", "fr-ru": "Xenova/opus-mt-fr-ru",
        "it-es": "Xenova/opus-mt-it-es", "it-fr": "Xenova/opus-mt-it-fr", "nl-fr": "Xenova/opus-mt-nl-fr",
        "no-de": "Xenova/opus-mt-no-de", "ro-fr": "Xenova/opus-mt-ro-fr", "ru-es": "Xenova/opus-mt-ru-es",
        "ru-fr": "Xenova/opus-mt-ru-fr", "ru-uk": "Xenova/opus-mt-ru-uk", "uk-ru": "Xenova/opus-mt-uk-ru",
    ]

    static let aliases: [String: String] = [
        "iw": "he", "ji": "yi", "in": "id", "jw": "jv", "nb": "no", "nn": "no", "fil": "tl", "tl": "tl", "mo": "ro",
        "zh-cn": "zh", "zh-sg": "zh", "zh-hans": "zh", "zh-tw": "zh-TW", "zh-hk": "zh-TW", "zh-mo": "zh-TW",
        "zh-hant": "zh-TW", "pt-br": "pt", "pt-pt": "pt",
    ]

    /// Languages written without spaces between sentences.
    public static let spaceless: Set<String> = ["zh", "zh-TW", "ja", "th", "lo", "km", "my"]

    public static func isSpaceless(_ code: String) -> Bool {
        spaceless.contains(normalize(code))
    }

    /// Detector and BCP-47 codes as the codes used here ("auto" when unknown).
    public static func normalize(_ code: String?) -> String {
        guard let code else { return "auto" }
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let underscore = value.range(of: "_") { value.replaceSubrange(underscore, with: "-") }
        value = value.lowercased()
        if value.isEmpty || value == "auto" || value == "und" { return "auto" }
        if let alias = aliases[value] { return alias }
        if value.hasPrefix("zh-") {
            let traditional = ["hant", "tw", "hk", "mo"].contains { value.contains($0) }
            return traditional ? "zh-TW" : "zh"
        }
        let primary = value.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? value
        return aliases[primary] ?? primary
    }

    /// The model chain for source → target: no steps when no translation is needed, nil when
    /// the pair is unsupported.
    public static func plan(from source: String, to target: String) -> TranslationRoute? {
        let from = normalize(source)
        let to = normalize(target)
        if to == "auto" { return nil }
        if from == to { return TranslationRoute(steps: []) }
        if let repository = direct["\(from)-\(to)"] {
            let step = TranslationStep(repository: repository, targetToken: nil, source: from, target: to, isLowQuality: false)
            return TranslationRoute(steps: [step])
        }
        if from == "en" {
            guard let step = fromEnglish(to) else { return nil }
            return TranslationRoute(steps: [step])
        }
        let first = toEnglishStep(from)
        if to == "en" { return TranslationRoute(steps: [first]) }
        guard let second = fromEnglish(to) else { return nil }
        return TranslationRoute(steps: [first, second])
    }

    private static func toEnglishStep(_ source: String) -> TranslationStep {
        if let repository = toEnglish[source] {
            return TranslationStep(repository: repository, targetToken: nil, source: source, target: "en", isLowQuality: false)
        }
        if romance.contains(source) {
            return TranslationStep(repository: romanceToEnglish, targetToken: nil, source: source, target: "en", isLowQuality: false)
        }
        if baltic.contains(source) {
            return TranslationStep(repository: balticToEnglish, targetToken: nil, source: source, target: "en", isLowQuality: false)
        }
        return TranslationStep(repository: multilingualToEnglish, targetToken: nil, source: source, target: "en", isLowQuality: true)
    }

    private static func fromEnglish(_ target: String) -> TranslationStep? {
        if let repository = fromEnglishModels[target] {
            let token = fromEnglishTokens[target]
            return TranslationStep(repository: repository, targetToken: token, source: "en", target: target, isLowQuality: false)
        }
        if let name = englishToMultilingualTokens[target] {
            let token = ">>\(name)<<"
            return TranslationStep(repository: englishToMultilingual, targetToken: token, source: "en", target: target, isLowQuality: true)
        }
        return nil
    }
}
