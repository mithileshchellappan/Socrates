import Foundation

// Simple LaTeX as Unicode text (docs/plan-learn-more.md §2.3): Greek letters, a few relations and
// operators, digit and letter sub- and superscripts. Used for copies and accessibility, and where
// a formula is that simple it can stand as text; anything else is drawn as a formula image.

public enum InlineMath {
    /// `T_0` → "T₀", `\alpha \le n^2` → "α ≤ n²"; nil when the LaTeX holds anything else.
    public static func unicode(_ latex: String) -> String? {
        var result = ""
        let characters = Array(latex)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                var name = ""
                var next = index + 1
                while next < characters.count, characters[next].isLetter {
                    name.append(characters[next])
                    next += 1
                }
                if name.isEmpty, next < characters.count {
                    // "\," "\;" "\!" "\ ": spacing.
                    if ",; :".contains(characters[next]) { result += " " } else if characters[next] != "!" { return nil }
                    index = next + 1
                    continue
                }
                guard let symbol = symbols[name] else { return nil }
                result += symbol
                index = next
            case "_", "^":
                let table = character == "_" ? subscripts : superscripts
                var next = index + 1
                var group = ""
                if next < characters.count, characters[next] == "{" {
                    next += 1
                    while next < characters.count, characters[next] != "}" {
                        group.append(characters[next])
                        next += 1
                    }
                    guard next < characters.count else { return nil }
                    next += 1
                } else if next < characters.count {
                    group = String(characters[next])
                    next += 1
                }
                guard !group.isEmpty else { return nil }
                for symbol in group {
                    guard let mapped = table[symbol] else { return nil }
                    result.append(mapped)
                }
                index = next
            case "{", "}":
                index += 1
            default:
                guard character.isLetter || character.isNumber || " +-=<>()[],.|:;!'/".contains(character) else { return nil }
                result += character == "-" ? "−" : String(character)
                index += 1
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Words for VoiceOver: the Unicode form when there is one, else the LaTeX with its commands
    /// read out ("a over b").
    public static func spoken(_ latex: String) -> String {
        if let text = unicode(latex) { return text }
        var text = latex
        text = text.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "$1 over $2", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "square root of $1", options: .regularExpression)
        for (name, symbol) in symbols {
            text = text.replacingOccurrences(of: "\\" + name, with: " \(symbol) ")
        }
        text = text.replacingOccurrences(of: #"[{}\\]"#, with: " ", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ",
        "Psi": "Ψ", "Omega": "Ω",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "implies": "⟹", "iff": "⟺", "gets": "←",
        "le": "≤", "leq": "≤", "ge": "≥", "geq": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡",
        "in": "∈", "notin": "∉", "subseteq": "⊆", "subset": "⊂", "cup": "∪", "cap": "∩", "emptyset": "∅",
        "cdot": "·", "times": "×", "pm": "±", "infty": "∞", "forall": "∀", "exists": "∃", "neg": "¬",
        "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨", "ldots": "…", "dots": "…", "cdots": "⋯",
        "max": "max", "min": "min", "log": "log", "ln": "ln", "mathrm": "", "text": "", "mathit": ""
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ",
        "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
    ]

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "T": "ᵀ"
    ]
}
