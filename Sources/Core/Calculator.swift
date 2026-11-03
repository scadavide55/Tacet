import Foundation

/// Sums typed in the command bar ("12*7+3", "(4,5 + 2) / 3", "2^10"), worked out on the spot like Spotlight, with no AI
/// and no network. A small parser of its own: NSExpression would stop Tacet on a sum typed halfway ("2+").
enum Calculator {
    private enum Token: Equatable { case number(Double), op(Character), open, close }

    /// The result, or nil when the text isn't a complete sum with at least one operation.
    static func evaluate(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= 120, let tokens = tokenize(trimmed),
              tokens.contains(where: { if case .op = $0 { return true } else { return false } }) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    /// The result as it's shown and copied, in the user's number format.
    static func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        f.usesGroupingSeparator = abs(value) >= 10_000
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func tokenize(_ s: String) -> [Token]? {
        var tokens: [Token] = []
        var number = ""
        func flush() -> Bool {
            guard !number.isEmpty else { return true }
            // A comma is a decimal point, as Italian and French write it.
            guard let v = Double(number.replacingOccurrences(of: ",", with: ".")) else { return false }
            tokens.append(.number(v))
            number = ""
            return true
        }
        for c in s {
            switch c {
            case "0"..."9", ".", ",":
                number.append(c)
            case " ":
                guard flush() else { return nil }
            case "+", "-", "*", "/", "^", "×", "÷", "x", "X":
                guard flush() else { return nil }
                let op: Character = c == "×" || c == "x" || c == "X" ? "*" : c == "÷" ? "/" : c
                tokens.append(.op(op))
            case "(":
                guard flush() else { return nil }
                tokens.append(.open)
            case ")":
                guard flush() else { return nil }
                tokens.append(.close)
            default:
                return nil
            }
        }
        guard flush(), !tokens.isEmpty else { return nil }
        return tokens
    }

    /// expression := term (+|- term)* · term := power (*|/ power)* · power := unary (^ power)? · unary := -unary | (expr) | number
    private struct Parser {
        let tokens: [Token]
        var i = 0
        var depth = 0
        var atEnd: Bool { i == tokens.count }

        private var next: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while case .op(let c)? = next, c == "+" || c == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while case .op(let c)? = next, c == "*" || c == "/" {
                i += 1
                guard let rhs = power() else { return nil }
                if c == "/" && rhs == 0 { return nil }
                value = c == "*" ? value * rhs : value / rhs
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if case .op("^")? = next {
                i += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            switch next {
            case .op("-")?:
                i += 1
                return unary().map { -$0 }
            case .op("+")?:
                i += 1
                return unary()
            case .number(let v)?:
                i += 1
                return v
            case .open?:
                // Deep nesting is refused rather than allowed to exhaust the stack.
                guard depth < 50 else { return nil }
                i += 1
                depth += 1
                defer { depth -= 1 }
                guard let value = expression(), next == .close else { return nil }
                i += 1
                return value
            default:
                return nil
            }
        }
    }
}
