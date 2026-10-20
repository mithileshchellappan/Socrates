import Foundation

// Code highlighting without a JavaScript engine (docs/plan-learn-more.md §2.3): line and block
// comments, strings (triple-quoted and raw ones too), numbers, each language's keywords,
// capitalised type names and calls (an identifier before "("). About twelve families: Python,
// Swift, Java/Kotlin, C/C++/C#/Objective-C, Go, Rust, JavaScript/TypeScript, SQL, shell,
// JSON/YAML/TOML, Dockerfile, pseudocode (keywords only). Synchronous, well under a millisecond
// for a 200-line block. The palette is DESIGN 3.1's "Code tokens" row (StudyPageUI).

public enum CodeTokenKind: Hashable, Sendable {
    case keyword
    /// A capitalised type name or a call.
    case type
    case string
    case number
    case comment
}

/// A highlighted range in UTF-16 offsets of the code (NSString ranges).
public struct CodeToken: Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var kind: CodeTokenKind
}

public enum CodeLexer {
    struct Grammar {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var quotes: [Character]
        var tripleQuotes = false
        var caseInsensitive = false
        /// Shell: `$name` and `${…}` read as names.
        var dollarNames = false
        var types = true
        /// Lower-case names drawn as types ("int", "str").
        var builtinTypes: Set<String> = []
    }

    /// The tokens of `code` in `language` (its fence's info string; aliases folded).
    public static func tokens(_ code: String, language: String) -> [CodeToken] {
        guard let grammar = grammar(for: language) else { return [] }
        let units = Array(code.utf16)
        var tokens: [CodeToken] = []
        var i = 0
        let count = units.count

        func matches(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf16)
            guard index + pattern.count <= count else { return false }
            for (offset, unit) in pattern.enumerated() where units[index + offset] != unit { return false }
            return true
        }
        func isIdentifierStart(_ unit: UInt16) -> Bool {
            (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95 || unit > 127
        }
        func isIdentifier(_ unit: UInt16) -> Bool {
            isIdentifierStart(unit) || (unit >= 48 && unit <= 57)
        }
        func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

        while i < count {
            let unit = units[i]
            // Comments.
            if let comment = grammar.lineComments.first(where: { matches($0, at: i) }) {
                _ = comment
                var end = i
                while end < count, units[end] != 10 { end += 1 }
                tokens.append(CodeToken(location: i, length: end - i, kind: .comment))
                i = end
                continue
            }
            if let block = grammar.blockComment, matches(block.open, at: i) {
                var end = i + block.open.utf16.count
                while end < count, !matches(block.close, at: end) { end += 1 }
                end = min(count, end + block.close.utf16.count)
                tokens.append(CodeToken(location: i, length: end - i, kind: .comment))
                i = end
                continue
            }
            // Strings (a raw or byte prefix in Python and Rust is part of the string).
            var start = i
            var quoteIndex = i
            if (unit == 114 || unit == 98 || unit == 102 || unit == 117), i + 1 < count, grammar.quotes.contains(Character(UnicodeScalar(units[i + 1]) ?? " ")),
               i == 0 || !isIdentifier(units[i - 1]) {
                quoteIndex = i + 1
            }
            if quoteIndex < count, let scalar = UnicodeScalar(units[quoteIndex]), grammar.quotes.contains(Character(scalar)) {
                start = i
                let quote = units[quoteIndex]
                let triple = grammar.tripleQuotes && quoteIndex + 2 < count && units[quoteIndex + 1] == quote && units[quoteIndex + 2] == quote
                var end = quoteIndex + (triple ? 3 : 1)
                while end < count {
                    if units[end] == 92 { // backslash
                        end += 2
                        continue
                    }
                    if triple {
                        if end + 2 < count, units[end] == quote, units[end + 1] == quote, units[end + 2] == quote {
                            end += 3
                            break
                        }
                    } else if units[end] == quote {
                        end += 1
                        break
                    } else if units[end] == 10, quote != 96 {
                        break
                    }
                    end += 1
                }
                end = min(end, count)
                tokens.append(CodeToken(location: start, length: end - start, kind: .string))
                i = end
                continue
            }
            // Numbers (not inside a name).
            if isDigit(unit) || (unit == 46 && i + 1 < count && isDigit(units[i + 1])), i == 0 || !isIdentifier(units[i - 1]) {
                var end = i + 1
                while end < count, isIdentifier(units[end]) || units[end] == 46 { end += 1 }
                tokens.append(CodeToken(location: i, length: end - i, kind: .number))
                i = end
                continue
            }
            // Shell variables.
            if grammar.dollarNames, unit == 36 {
                var end = i + 1
                if end < count, units[end] == 123 {
                    while end < count, units[end] != 125 { end += 1 }
                    end = min(count, end + 1)
                } else {
                    while end < count, isIdentifier(units[end]) { end += 1 }
                }
                if end > i + 1 { tokens.append(CodeToken(location: i, length: end - i, kind: .type)) }
                i = max(end, i + 1)
                continue
            }
            // Names: keywords, types, calls.
            if isIdentifierStart(unit) {
                var end = i + 1
                while end < count, isIdentifier(units[end]) || (grammar.dollarNames && units[end] == 45) { end += 1 }
                let word = String(utf16CodeUnits: Array(units[i..<end]), count: end - i)
                let key = grammar.caseInsensitive ? word.lowercased() : word
                if grammar.keywords.contains(key) {
                    tokens.append(CodeToken(location: i, length: end - i, kind: .keyword))
                } else if grammar.types {
                    var next = end
                    while next < count, units[next] == 32 { next += 1 }
                    let isCall = next < count && units[next] == 40
                    let isType = grammar.builtinTypes.contains(word)
                        || unit >= 65 && unit <= 90 && word.count > 1 && !word.allSatisfy { $0.isUppercase || $0 == "_" || $0.isNumber }
                    if isCall || isType { tokens.append(CodeToken(location: i, length: end - i, kind: .type)) }
                }
                i = end
                continue
            }
            i += 1
        }
        return tokens
    }

    /// The family of a fence's language; nil: plain text.
    static func grammar(for language: String) -> Grammar? {
        let cLike = Grammar(keywords: [], lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"])
        switch language.lowercased() {
        case "python", "py", "python3":
            return Grammar(
                keywords: python, lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true,
                builtinTypes: ["int", "str", "float", "bool", "list", "dict", "set", "tuple", "bytes", "object"]
            )
        case "swift":
            var grammar = cLike
            grammar.keywords = swift
            grammar.quotes = ["\""]
            grammar.tripleQuotes = true
            return grammar
        case "java", "kotlin", "kt", "scala":
            var grammar = cLike
            grammar.keywords = java
            grammar.tripleQuotes = true
            return grammar
        case "c", "cpp", "c++", "cc", "h", "hpp", "objc", "objective-c", "cs", "csharp", "c#":
            var grammar = cLike
            grammar.keywords = c
            return grammar
        case "go", "golang":
            var grammar = cLike
            grammar.keywords = go
            grammar.quotes = ["\"", "'", "`"]
            return grammar
        case "rust", "rs":
            var grammar = cLike
            grammar.keywords = rust
            grammar.quotes = ["\""]
            return grammar
        case "javascript", "js", "typescript", "ts", "jsx", "tsx", "node":
            var grammar = cLike
            grammar.keywords = javascript
            grammar.quotes = ["\"", "'", "`"]
            return grammar
        case "sql", "postgres", "postgresql", "mysql", "sqlite":
            return Grammar(keywords: sql, lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], caseInsensitive: true, types: false)
        case "sh", "bash", "zsh", "shell", "console", "terminal":
            return Grammar(keywords: shell, lineComments: ["#"], quotes: ["\"", "'"], dollarNames: true, types: false)
        case "json", "jsonc":
            return Grammar(keywords: ["true", "false", "null"], lineComments: ["//"], quotes: ["\""], types: false)
        case "yaml", "yml":
            return Grammar(keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], quotes: ["\"", "'"], types: false)
        case "toml", "ini":
            return Grammar(keywords: ["true", "false"], lineComments: ["#", ";"], quotes: ["\"", "'"], tripleQuotes: true, types: false)
        case "dockerfile", "docker":
            return Grammar(keywords: docker, lineComments: ["#"], quotes: ["\"", "'"], caseInsensitive: false, dollarNames: true, types: false)
        case "pseudocode", "pseudo", "algorithm", "text-algorithm":
            return Grammar(keywords: pseudocode, lineComments: ["//", "#"], quotes: ["\""], caseInsensitive: true, types: false)
        default:
            return nil
        }
    }

    static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass",
        "raise", "return", "try", "while", "with", "yield", "None", "True", "False", "match", "case"
    ]
    static let swift: Set<String> = [
        "actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else",
        "enum", "extension", "fallthrough", "false", "for", "func", "guard", "if", "import", "in", "init", "inout",
        "internal", "is", "let", "nil", "private", "protocol", "public", "repeat", "return", "self", "Self", "static",
        "struct", "super", "switch", "throw", "throws", "true", "try", "var", "where", "while", "some", "any", "mutating"
    ]
    static let java: Set<String> = [
        "abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "continue", "default", "do", "double",
        "else", "enum", "extends", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "new", "null", "package", "private", "protected", "public", "return", "short", "static",
        "super", "switch", "synchronized", "this", "throw", "throws", "try", "void", "volatile", "while", "true", "false",
        "fun", "val", "var", "when", "object", "data", "override", "is", "in", "companion"
    ]
    static let c: Set<String> = [
        "auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do",
        "double", "else", "enum", "extern", "false", "float", "for", "goto", "if", "inline", "int", "long", "namespace",
        "new", "nullptr", "NULL", "private", "protected", "public", "register", "return", "short", "signed", "sizeof",
        "static", "struct", "switch", "template", "this", "true", "typedef", "typename", "union", "unsigned", "using",
        "virtual", "void", "volatile", "while", "size_t", "uint8_t", "uint32_t", "uint64_t", "int32_t", "int64_t",
        "string", "var", "foreach", "in", "out", "ref", "readonly", "override", "async", "await"
    ]
    static let go: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
        "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type",
        "var", "nil", "true", "false", "int", "string", "bool", "error", "byte", "float64"
    ]
    static let rust: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "Some", "None", "Ok", "Err"
    ]
    static let javascript: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof",
        "let", "new", "null", "of", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
        "var", "void", "while", "yield", "interface", "type", "enum", "implements", "readonly", "as", "number", "string",
        "boolean"
    ]
    static let sql: Set<String> = [
        "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create",
        "table", "index", "view", "drop", "alter", "add", "primary", "key", "foreign", "references", "join", "inner",
        "left", "right", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "distinct", "union",
        "all", "null", "is", "in", "exists", "between", "like", "case", "when", "then", "else", "end", "count", "sum",
        "avg", "min", "max", "integer", "text", "varchar", "boolean", "unique", "default", "begin", "commit", "rollback",
        "transaction", "with", "asc", "desc"
    ]
    static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
        "return", "export", "local", "echo", "cd", "sudo", "exit", "set", "source"
    ]
    static let docker: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG",
        "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS"
    ]
    static let pseudocode: Set<String> = [
        "if", "then", "else", "end", "for", "each", "to", "do", "while", "repeat", "until", "return", "function",
        "procedure", "algorithm", "input", "output", "and", "or", "not", "in", "let", "send", "receive", "upon", "on",
        "wait", "when", "true", "false", "nil", "null", "begin"
    ]
}
