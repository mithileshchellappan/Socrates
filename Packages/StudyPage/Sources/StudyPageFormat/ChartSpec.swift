import Foundation

// A `chart` fence (docs/plan-learn-more.md §2.3): a small JSON spec drawn with Swift Charts. Lines,
// bars, scatter and area from data; function plots from expressions our own parser evaluates
// (never NSExpression, whose FUNCTION() can call methods, and never JavaScriptCore).

/// A chart as the model writes it.
public struct ChartSpec: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case line, bar, scatter, area, function
    }

    public struct Axis: Hashable, Sendable, Codable {
        public enum Scale: String, Hashable, Sendable, Codable { case linear, log }
        public var label: String?
        public var unit: String?
        public var scale: Scale?
        /// [lower, upper].
        public var domain: [Double]?

        public init(label: String? = nil, unit: String? = nil, scale: Scale? = nil, domain: [Double]? = nil) {
            self.label = label
            self.unit = unit
            self.scale = scale
            self.domain = domain
        }

        /// "processes n", "latency (ms)".
        public var title: String? {
            let parts = [label, unit.map { "(\($0))" }].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }

        public var range: ClosedRange<Double>? {
            guard let domain, domain.count == 2, domain[0] < domain[1], domain.allSatisfy(\.isFinite) else { return nil }
            return domain[0]...domain[1]
        }
    }

    public struct Series: Hashable, Sendable, Codable {
        public var name: String
        /// [[x, y]].
        public var points: [[Double]]

        public init(name: String, points: [[Double]]) {
            self.name = name
            self.points = points
        }
    }

    public struct Bar: Hashable, Sendable, Codable {
        public var label: String
        public var value: Double
        public var series: String?

        public init(label: String, value: Double, series: String? = nil) {
            self.label = label
            self.value = value
            self.series = series
        }
    }

    public struct Function: Hashable, Sendable, Codable {
        public var name: String
        public var expr: String

        public init(name: String, expr: String) {
            self.name = name
            self.expr = expr
        }
    }

    public struct Mark: Hashable, Sendable, Codable {
        public var x: Double
        public var label: String

        public init(x: Double, label: String) {
            self.x = x
            self.label = label
        }
    }

    public var kind: Kind
    public var title: String?
    public var caption: String?
    public var x: Axis?
    public var y: Axis?
    public var series: [Series]?
    public var bars: [Bar]?
    public var functions: [Function]?
    public var marks: [Mark]?

    public init(
        kind: Kind, title: String? = nil, caption: String? = nil, x: Axis? = nil, y: Axis? = nil, series: [Series]? = nil,
        bars: [Bar]? = nil, functions: [Function]? = nil, marks: [Mark]? = nil
    ) {
        self.kind = kind
        self.title = title
        self.caption = caption
        self.x = x
        self.y = y
        self.series = series
        self.bars = bars
        self.functions = functions
        self.marks = marks
    }

    /// At most 6 series (or functions), 500 points in all.
    public static let seriesLimit = 6
    public static let pointLimit = 500

    /// The fence's JSON as a spec, or why it is not one (one short line for the repair call).
    public static func parse(_ json: String) -> Result<ChartSpec, ChartSpecError> {
        let spec: ChartSpec
        do {
            spec = try JSONDecoder().decode(ChartSpec.self, from: Data(json.utf8))
        } catch {
            return .failure(ChartSpecError("chart: the JSON does not decode (\(Self.describe(error)))"))
        }
        if let problem = spec.problem { return .failure(ChartSpecError(problem)) }
        return .success(spec)
    }

    /// What keeps it from drawing; nil when it draws.
    public var problem: String? {
        switch kind {
        case .bar:
            guard let bars, !bars.isEmpty else { return "chart: a bar chart needs \"bars\"" }
            guard bars.count <= Self.pointLimit else { return "chart: more than \(Self.pointLimit) bars" }
            guard bars.allSatisfy({ $0.value.isFinite }) else { return "chart: a bar's value is not a number" }
            let names = Set(bars.compactMap(\.series))
            guard names.count <= Self.seriesLimit else { return "chart: more than \(Self.seriesLimit) series" }
        case .line, .scatter, .area:
            guard let series, !series.isEmpty else { return "chart: a \(kind.rawValue) chart needs \"series\"" }
            guard series.count <= Self.seriesLimit else { return "chart: more than \(Self.seriesLimit) series" }
            let count = series.reduce(0) { $0 + $1.points.count }
            guard count <= Self.pointLimit else { return "chart: more than \(Self.pointLimit) points" }
            guard series.allSatisfy({ $0.points.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isFinite) } }) else {
                return "chart: every point is [x, y] with two numbers"
            }
            if x?.scale == .log || y?.scale == .log {
                guard series.allSatisfy({ $0.points.allSatisfy { (x?.scale != .log || $0[0] > 0) && (y?.scale != .log || $0[1] > 0) } }) else {
                    return "chart: a log axis needs positive values"
                }
            }
        case .function:
            guard let functions, !functions.isEmpty else { return "chart: a function chart needs \"functions\"" }
            guard functions.count <= Self.seriesLimit else { return "chart: more than \(Self.seriesLimit) functions" }
            guard x?.range != nil else { return "chart: a function chart needs x.domain [lower, upper]" }
            for function in functions {
                switch ChartExpression.parse(function.expr) {
                case .failure(let error): return "chart: \(function.name): \(error.message)"
                case .success: break
                }
            }
        }
        return nil
    }

    /// The function plot's points (`samples` per function over the x domain), drop-outs (no value,
    /// infinite) left out.
    public func sampled(samples: Int = 120) -> [Series] {
        guard kind == .function, let functions, let range = x?.range else { return series ?? [] }
        let log = x?.scale == .log && range.lowerBound > 0
        return functions.map { function in
            guard case .success(let expression) = ChartExpression.parse(function.expr) else { return Series(name: function.name, points: []) }
            let count = max(2, samples)
            let points: [[Double]] = (0..<count).compactMap { index in
                let t = Double(index) / Double(count - 1)
                let x = log
                    ? exp(Foundation.log(range.lowerBound) + t * (Foundation.log(range.upperBound) - Foundation.log(range.lowerBound)))
                    : range.lowerBound + t * (range.upperBound - range.lowerBound)
                guard let y = expression.evaluate(x), y.isFinite, abs(y) < 1e12 else { return nil }
                return [x, y]
            }
            return Series(name: function.name, points: points)
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _)?: "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?:
            "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context)?: context.codingPath.isEmpty ? "not JSON" : "bad value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        default: "not JSON"
        }
    }
}

public struct ChartSpecError: Error, Hashable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - Expressions

/// A function of one variable (`x` or `n`): numbers, `+ - * / ^`, unary minus, parentheses,
/// `sin cos tan exp ln log2 log10 sqrt abs floor ceil min max`, `pi`, `e`. Implicit
/// multiplication of a number and what follows ("2x", "3(x+1)") is read as such.
public indirect enum ChartExpression: Hashable, Sendable {
    case number(Double)
    case variable
    case negate(ChartExpression)
    case binary(Character, ChartExpression, ChartExpression)
    case call(String, [ChartExpression])

    public struct ParseError: Error, Hashable, Sendable {
        public var message: String
    }

    public static func parse(_ text: String) -> Result<ChartExpression, ParseError> {
        var parser = Parser(Array(text.lowercased()))
        do {
            let expression = try parser.expression()
            parser.skipSpaces()
            guard parser.index == parser.characters.count else {
                throw ParseError(message: "unexpected \"\(parser.characters[parser.index])\"")
            }
            return .success(expression)
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(ParseError(message: "unreadable"))
        }
    }

    public func evaluate(_ x: Double) -> Double? {
        switch self {
        case .number(let value): return value
        case .variable: return x
        case .negate(let inner): return inner.evaluate(x).map { -$0 }
        case .binary(let op, let lhs, let rhs):
            guard let a = lhs.evaluate(x), let b = rhs.evaluate(x) else { return nil }
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return b == 0 ? nil : a / b
            case "^": return pow(a, b)
            default: return nil
            }
        case .call(let name, let arguments):
            let values = arguments.compactMap { $0.evaluate(x) }
            guard values.count == arguments.count, let first = values.first else { return nil }
            switch name {
            case "sin": return sin(first)
            case "cos": return cos(first)
            case "tan": return tan(first)
            case "exp": return exp(first)
            case "ln": return first > 0 ? log(first) : nil
            case "log": return first > 0 ? log10(first) : nil
            case "log2": return first > 0 ? log2(first) : nil
            case "log10": return first > 0 ? log10(first) : nil
            case "sqrt": return first >= 0 ? first.squareRoot() : nil
            case "abs": return abs(first)
            case "floor": return floor(first)
            case "ceil": return ceil(first)
            case "min": return values.min()
            case "max": return values.max()
            default: return nil
            }
        }
    }

    static let functions: Set<String> = ["sin", "cos", "tan", "exp", "ln", "log", "log2", "log10", "sqrt", "abs", "floor", "ceil", "min", "max"]

    /// Recursive descent: expression = term (± term)*; term = power ((*|/|implicit) power)*;
    /// power = unary (^ power)?; unary = -unary | primary.
    struct Parser {
        let characters: [Character]
        var index = 0
        var depth = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        mutating func peek() -> Character? {
            skipSpaces()
            return index < characters.count ? characters[index] : nil
        }

        mutating func expression() throws -> ChartExpression {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw ParseError(message: "nested too deeply") }
            var result = try term()
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                result = .binary(op, result, try term())
            }
            return result
        }

        mutating func term() throws -> ChartExpression {
            var result = try power()
            while let next = peek() {
                if next == "*" || next == "/" || next == "×" || next == "·" {
                    index += 1
                    result = .binary(next == "/" ? "/" : "*", result, try power())
                } else if next == "(" || next.isLetter {
                    // Implicit multiplication: "2x", "3(x + 1)", "x sin(x)".
                    result = .binary("*", result, try power())
                } else {
                    break
                }
            }
            return result
        }

        mutating func power() throws -> ChartExpression {
            let base = try unary()
            if peek() == "^" {
                index += 1
                return .binary("^", base, try power())
            }
            return base
        }

        mutating func unary() throws -> ChartExpression {
            if peek() == "-" {
                index += 1
                return .negate(try unary())
            }
            if peek() == "+" {
                index += 1
                return try unary()
            }
            return try primary()
        }

        mutating func primary() throws -> ChartExpression {
            guard let next = peek() else { throw ParseError(message: "ends too early") }
            if next == "(" {
                index += 1
                let inner = try expression()
                guard peek() == ")" else { throw ParseError(message: "a \"(\" is not closed") }
                index += 1
                return inner
            }
            if next.isNumber || next == "." {
                var text = ""
                while index < characters.count, characters[index].isNumber || characters[index] == "." {
                    text.append(characters[index])
                    index += 1
                }
                // An exponent: 1e-6.
                if index + 1 < characters.count, characters[index] == "e",
                   characters[index + 1].isNumber || ((characters[index + 1] == "-" || characters[index + 1] == "+") && index + 2 < characters.count && characters[index + 2].isNumber) {
                    text.append("e")
                    index += 1
                    if characters[index] == "-" || characters[index] == "+" {
                        text.append(characters[index])
                        index += 1
                    }
                    while index < characters.count, characters[index].isNumber {
                        text.append(characters[index])
                        index += 1
                    }
                }
                guard let value = Double(text) else { throw ParseError(message: "\"\(text)\" is not a number") }
                return .number(value)
            }
            if next.isLetter {
                var name = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber {
                    name.append(characters[index])
                    index += 1
                }
                switch name {
                case "x", "n": return .variable
                case "pi", "π": return .number(.pi)
                case "e": return .number(M_E)
                default:
                    guard Self.isFunction(name) else { throw ParseError(message: "unknown name \"\(name)\"") }
                    guard peek() == "(" else { throw ParseError(message: "\(name) needs (…)") }
                    index += 1
                    var arguments = [try expression()]
                    while peek() == "," {
                        index += 1
                        arguments.append(try expression())
                    }
                    guard peek() == ")" else { throw ParseError(message: "\(name)( is not closed") }
                    index += 1
                    let arity = (name == "min" || name == "max") ? 1...8 : 1...1
                    guard arity.contains(arguments.count) else { throw ParseError(message: "\(name) takes \(arity.upperBound == 1 ? "one value" : "values")") }
                    return .call(name, arguments)
                }
            }
            throw ParseError(message: "unexpected \"\(next)\"")
        }

        static func isFunction(_ name: String) -> Bool {
            ChartExpression.functions.contains(name)
        }
    }
}
