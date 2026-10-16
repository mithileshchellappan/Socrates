/// The original Porter (1980) English stemmer, on ASCII lowercase words.
///
/// "reporting"/"reporter" → "report", "evaluation"/"evaluate" → "evalu". Words with non-ASCII letters
/// (German umlauts, ß) are returned unchanged; German words without them get English suffix rules, which
/// is harmless because slides and speech are stemmed identically.
enum PorterStemmer {
    static func stem(_ word: String) -> String {
        guard word.count > 2, word.utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return word }
        var stemmer = Buffer(Array(word.utf8))
        stemmer.step1a()
        stemmer.step1b()
        stemmer.step1c()
        stemmer.step2()
        stemmer.step3()
        stemmer.step4()
        stemmer.step5()
        return String(decoding: stemmer.letters, as: UTF8.self)
    }

    private struct Buffer {
        var letters: [UInt8]

        init(_ letters: [UInt8]) {
            self.letters = letters
        }

        private static let a = UInt8(ascii: "a"), e = UInt8(ascii: "e"), i = UInt8(ascii: "i")
        private static let o = UInt8(ascii: "o"), u = UInt8(ascii: "u"), y = UInt8(ascii: "y")
        private static let w = UInt8(ascii: "w"), x = UInt8(ascii: "x")
        private static let l = UInt8(ascii: "l"), s = UInt8(ascii: "s"), z = UInt8(ascii: "z"), t = UInt8(ascii: "t")

        /// Consonant at `index` in `word` (y is a consonant at the start or after a vowel).
        private static func isConsonant(_ word: ArraySlice<UInt8>, _ index: Int) -> Bool {
            switch word[index] {
            case a, e, i, o, u: return false
            case y: return index == word.startIndex ? true : !isConsonant(word, index - 1)
            default: return true
            }
        }

        /// Number of VC sequences in `stem`.
        private static func measure(_ stem: ArraySlice<UInt8>) -> Int {
            var count = 0
            var index = stem.startIndex
            while index < stem.endIndex, isConsonant(stem, index) { index += 1 }
            while index < stem.endIndex {
                while index < stem.endIndex, !isConsonant(stem, index) { index += 1 }
                guard index < stem.endIndex else { break }
                count += 1
                while index < stem.endIndex, isConsonant(stem, index) { index += 1 }
            }
            return count
        }

        private static func containsVowel(_ stem: ArraySlice<UInt8>) -> Bool {
            stem.indices.contains { !isConsonant(stem, $0) }
        }

        private static func endsWithDoubleConsonant(_ stem: ArraySlice<UInt8>) -> Bool {
            let end = stem.endIndex
            guard stem.count >= 2 else { return false }
            return stem[end - 1] == stem[end - 2] && isConsonant(stem, end - 1)
        }

        /// consonant-vowel-consonant at the end, last consonant not w, x or y.
        private static func endsCVC(_ stem: ArraySlice<UInt8>) -> Bool {
            let end = stem.endIndex
            guard stem.count >= 3 else { return false }
            let last = stem[end - 1]
            return isConsonant(stem, end - 3) && !isConsonant(stem, end - 2) && isConsonant(stem, end - 1)
                && last != w && last != x && last != y
        }

        private func hasSuffix(_ suffix: StaticString) -> Bool {
            hasSuffix(UnsafeBufferPointer(start: suffix.utf8Start, count: suffix.utf8CodeUnitCount))
        }

        private func hasSuffix(_ suffix: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = suffix.count
            guard letters.count >= count else { return false }
            let offset = letters.count - count
            for index in 0..<count where letters[offset + index] != suffix[index] { return false }
            return true
        }

        private func stem(removing suffix: StaticString) -> ArraySlice<UInt8> {
            letters[..<(letters.count - suffix.utf8CodeUnitCount)]
        }

        private mutating func replace(_ suffix: StaticString, with replacement: StaticString) {
            letters.removeLast(suffix.utf8CodeUnitCount)
            letters.append(contentsOf: UnsafeBufferPointer(start: replacement.utf8Start, count: replacement.utf8CodeUnitCount))
        }

        /// Applies the first (longest) matching rule when its stem has measure > `minimumMeasure`.
        private mutating func applyRules(_ rules: [(StaticString, StaticString)], minimumMeasure: Int) {
            for (suffix, replacement) in rules where hasSuffix(suffix) {
                if Self.measure(stem(removing: suffix)) > minimumMeasure {
                    replace(suffix, with: replacement)
                }
                return
            }
        }

        mutating func step1a() {
            if hasSuffix("sses") {
                replace("sses", with: "ss")
            } else if hasSuffix("ies") {
                replace("ies", with: "i")
            } else if hasSuffix("ss") {
                return
            } else if hasSuffix("s") {
                replace("s", with: "")
            }
        }

        mutating func step1b() {
            if hasSuffix("eed") {
                if Self.measure(stem(removing: "eed")) > 0 { replace("eed", with: "ee") }
                return
            }
            if hasSuffix("ed"), Self.containsVowel(stem(removing: "ed")) {
                replace("ed", with: "")
            } else if hasSuffix("ing"), Self.containsVowel(stem(removing: "ing")) {
                replace("ing", with: "")
            } else {
                return
            }
            if hasSuffix("at") || hasSuffix("bl") || hasSuffix("iz") {
                letters.append(Self.e)
            } else if Self.endsWithDoubleConsonant(letters[...]),
                      let last = letters.last, last != Self.l, last != Self.s, last != Self.z {
                letters.removeLast()
            } else if Self.measure(letters[...]) == 1, Self.endsCVC(letters[...]) {
                letters.append(Self.e)
            }
        }

        mutating func step1c() {
            if hasSuffix("y"), Self.containsVowel(stem(removing: "y")) {
                replace("y", with: "i")
            }
        }

        /// Longest suffixes first, so the first match is the longest one.
        private static let step2Rules: [(StaticString, StaticString)] = [
            ("ational", "ate"), ("ization", "ize"), ("iveness", "ive"), ("fulness", "ful"), ("ousness", "ous"),
            ("tional", "tion"), ("biliti", "ble"), ("entli", "ent"), ("ousli", "ous"), ("ation", "ate"),
            ("alism", "al"), ("aliti", "al"), ("iviti", "ive"), ("enci", "ence"), ("anci", "ance"),
            ("izer", "ize"), ("abli", "able"), ("alli", "al"), ("ator", "ate"), ("logi", "log"), ("eli", "e")
        ]
        private static let step3Rules: [(StaticString, StaticString)] = [
            ("icate", "ic"), ("ative", ""), ("alize", "al"), ("iciti", "ic"), ("ical", "ic"), ("ness", ""), ("ful", "")
        ]
        private static let step4Suffixes: [StaticString] = [
            "ement", "ance", "ence", "able", "ible", "ment", "ant", "ent", "ism", "ate", "iti", "ous",
            "ive", "ize", "al", "er", "ic", "ou"
        ]

        mutating func step2() {
            applyRules(Self.step2Rules, minimumMeasure: 0)
        }

        mutating func step3() {
            applyRules(Self.step3Rules, minimumMeasure: 0)
        }

        mutating func step4() {
            // "ion" is the only listed suffix ending in "ion"; it needs a stem ending in s or t.
            if hasSuffix("ion") {
                let stem = stem(removing: "ion")
                if let last = stem.last, last == Self.s || last == Self.t, Self.measure(stem) > 1 {
                    replace("ion", with: "")
                }
                return
            }
            for suffix in Self.step4Suffixes where hasSuffix(suffix) {
                if Self.measure(stem(removing: suffix)) > 1 { replace(suffix, with: "") }
                return
            }
        }

        mutating func step5() {
            if hasSuffix("e") {
                let stem = stem(removing: "e")
                let measure = Self.measure(stem)
                if measure > 1 || (measure == 1 && !Self.endsCVC(stem)) { letters.removeLast() }
            }
            if Self.measure(letters[...]) > 1, Self.endsWithDoubleConsonant(letters[...]), letters.last == Self.l {
                letters.removeLast()
            }
        }
    }
}
