import Foundation

/// Splits slide text and transcript text into comparable terms.
///
/// - NFKC-normalizes first, so PDF ligatures ("ﬁ") and math alphanumerics ("𝑇𝑃") become plain letters.
/// - A token is a maximal run of Unicode letters, digits and combining marks (`\p{L}\p{N}\p{M}`), so
///   umlauts and ß stay inside words; hyphens, apostrophes and punctuation split.
/// - Lowercased; tokens shorter than 2 characters or without any letter are dropped.
/// - English and German stopwords (including spoken fillers and URL parts) are removed.
/// - English words are stemmed (Porter) so "reporter"/"reporting" and "evaluate"/"evaluation" meet.
public struct Tokenizer: Hashable, Sendable {
    public enum Stemming: String, Hashable, Sendable, CaseIterable {
        case none
        /// "instances" → "instance", "policies" → "policy".
        case plurals
        /// Porter (1980) on ASCII words.
        case porter
    }

    public var stopwords: Set<String>
    public var minimumLength: Int
    public var stemming: Stemming

    public init(stopwords: Set<String> = Stopwords.all, minimumLength: Int = 2, stemming: Stemming = .porter) {
        self.stopwords = stopwords
        self.minimumLength = minimumLength
        self.stemming = stemming
    }

    /// Normalized terms in order of appearance.
    public func terms(in text: String) -> [String] {
        var output: [String] = []
        forEachRawToken(in: text) { raw in
            if let term = normalize(raw) { output.append(term) }
        }
        return output
    }

    /// Raw NFKC-lowercased tokens before stopword filtering and folding (every spoken word counts
    /// when spreading a line's tokens over its duration).
    public func rawTokens(in text: String) -> [String] {
        var output: [String] = []
        forEachRawToken(in: text) { output.append($0) }
        return output
    }

    /// Maps one raw (already lowercased) token to a term, or nil when it is a stopword/too short/numeric.
    public func normalize(_ token: String) -> String? {
        let raw = Self.strippingGluedNumber(token)
        guard raw.count >= minimumLength, raw.unicodeScalars.contains(where: Self.isLetter) else { return nil }
        guard !stopwords.contains(raw) else { return nil }
        let term = switch stemming {
        case .none: raw
        case .plurals: Self.foldPlural(raw)
        case .porter: PorterStemmer.stem(raw)
        }
        guard term.count >= minimumLength, !stopwords.contains(term) else { return nil }
        return term
    }

    func forEachRawToken(in text: String, _ body: (String) -> Void) {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var current = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            if Self.isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                body(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { body(String(current)) }
    }

    /// PDF text extraction glues page numbers onto the last word ("Bitmovin36"): a word of at least three
    /// letters followed only by digits loses the digits. Short mixed tokens ("x86", "c4", "ec2") are kept.
    static func strippingGluedNumber(_ token: String) -> String {
        let scalars = token.unicodeScalars
        guard let last = scalars.last, last.properties.numericType != nil else { return token }
        var letters = 0
        var digitsStarted = false
        for scalar in scalars {
            if scalar.properties.numericType != nil {
                digitsStarted = true
            } else if digitsStarted || !isLetter(scalar) {
                return token
            } else {
                letters += 1
            }
        }
        guard letters >= 3 else { return token }
        return String(String.UnicodeScalarView(scalars.prefix(letters)))
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
        }
    }

    /// Conservative English plural folding (Porter step 1a without the "ss" rules that over-fire on German).
    static func foldPlural(_ word: String) -> String {
        let count = word.count
        guard count > 3, word.hasSuffix("s") else { return word }
        if word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("is") || word.hasSuffix("ys") {
            return word
        }
        if count > 4, word.hasSuffix("ies") {
            return String(word.dropLast(3)) + "y"
        }
        return String(word.dropLast())
    }
}

/// Stopword lists. Lowercase, surface forms (before plural folding).
public enum Stopwords {
    public static let english: Set<String> = Set("""
        a about above after again against all almost along already also although always am among an and another any \
        anybody anyone anything anyway anyways are aren around as at away back be became because become becomes been \
        before being below besides between beyond both but by can cannot cant could couldn did didn do does doesn doing \
        don done down during each either else enough especially etc even ever every everybody everyone everything \
        exactly few first for from further get gets getting give given gives go goes going gone got gotten had hadn has \
        hasn have haven having he her here hers herself him himself his how however i if in instead into is isn it its \
        itself just last least less let lets like likely ll made make makes making many may maybe me might mine more most \
        mostly much must my myself near need needs neither never next no nobody none nor not nothing now of off often \
        on once one ones only onto or other others otherwise our ours ourselves out over own per perhaps please put \
        quite rather re really same say says said see seen seem seems shall she should shouldn since so some somebody \
        someone something sometimes somewhat somehow still such sure take taken than that thats the their theirs them \
        themselves then there therefore these they thing things this those though through thus to together too toward \
        towards under until up upon us use used uses using ve very via want wants was wasn way ways we well were weren \
        what whatever when whenever where whether which while who whoever whole whom whose why will with within without \
        won would wouldn yet you your yours yourself yourselves \
        actually alright anyhow basically certainly clearly definitely gonna gotta guess guys hmm hm huh kind kinda \
        know known look looking looks lot lots mean means mhm mm oh ok okay right sort sorta stuff talk talking tell \
        think thinking thought uh uhm um umm wanna yeah yep yes yo two three four five six seven eight nine ten \
        today again everything here hello hey thank thanks bit little big good great nice new old able \
        https http www com org net html pdf
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    public static let german: Set<String> = Set("""
        aber alle allem allen aller alles als also am an ander andere anderem anderen anderer anderes anders auch auf \
        aus bei beim bin bis bist bitte bzw da dabei dadurch dafür dagegen daher dahin damals damit danach dann daran \
        darauf daraus darin darüber darum darunter das dass dazu dein deine dem den denen denn dennoch der deren des \
        deshalb dessen dich die dies diese diesem diesen dieser dieses dir doch dort du durch eben ein eine einem einen \
        einer eines einfach einige einmal er es etwa etwas euch euer eure für gar gegen genau gerade gewesen ging gut \
        habe haben hast hat hatte hatten hier hin hinter ich ihm ihn ihnen ihr ihre im immer in ins ist ja jede jedem \
        jeden jeder jedes jetzt kann kannst kein keine keinem keinen keiner können könnte machen macht mal man manche \
        mehr mein meine meinem meinen meiner mich mir mit muss musst müssen nach nein nicht nichts noch nun nur ob oder \
        ohne schon sehr sein seine seinem seinen seiner seit selbst sich sie sind so solche soll sollen sollte sondern \
        sonst sowie später statt um und uns unser unsere unter viel viele vom von vor wann war waren warum was weil \
        weiter welche welchem welchen welcher welches wenn wer werde werden wie wieder will wir wird wirklich wo wollen \
        wurde wurden zu zum zur zwar zwei drei vier über überhaupt \
        äh ähm eh halt na naja okay quasi sozusagen genau irgendwie eigentlich gibt geht gehen ganz heute hallo danke \
        sagen sagt gesagt mache machen weiß wissen glaube denke ne nee joa jo
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    public static let all: Set<String> = english.union(german)
}
