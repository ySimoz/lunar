import Foundation

/// Errors thrown while tokenizing or parsing a mathematical expression.
public enum MathParseError: LocalizedError, Sendable, Equatable {
    case emptyExpression
    case unexpectedCharacter(Character)
    case unexpectedToken(String)
    case missingClosingParenthesis
    case unknownIdentifier(String)
    case multipleEqualsSigns

    public var errorDescription: String? {
        switch self {
        case .emptyExpression: "Enter a mathematical expression."
        case .unexpectedCharacter(let ch): "Unexpected character '\(ch)'."
        case .unexpectedToken(let tok): "Unexpected token '\(tok)'."
        case .missingClosingParenthesis: "Missing closing parenthesis ')'."
        case .unknownIdentifier(let name): "Unknown identifier '\(name)'."
        case .multipleEqualsSigns: "Equation may contain at most one '='."
        }
    }
}

/// Errors thrown by symbolic CAS commands (`diff`, `integrate`, `solve`).
public enum MathCASError: LocalizedError, Sendable, Equatable {
    case invalidCommandSyntax(String)
    case invalidVariable(String)
    case invalidBounds(String)
    case nonFiniteResult

    public var errorDescription: String? {
        switch self {
        case .invalidCommandSyntax(let msg): msg
        case .invalidVariable(let v): "Invalid variable '\(v)'. Expected a single letter."
        case .invalidBounds(let msg): msg
        case .nonFiniteResult: "Result is undefined or non-finite."
        }
    }
}

/// Result returned by evaluating a CAS console input line.
public struct CASCommandResult: Sendable, Equatable {
    public let inputLatex: String
    public let outputLatex: String
    public let plottableExpression: String?
    public let shouldAutoPlot: Bool

    public init(
        inputLatex: String,
        outputLatex: String,
        plottableExpression: String? = nil,
        shouldAutoPlot: Bool = false
    ) {
        self.inputLatex = inputLatex
        self.outputLatex = outputLatex
        self.plottableExpression = plottableExpression
        self.shouldAutoPlot = shouldAutoPlot
    }
}

/// AST node for a compiled mathematical expression in variables `(x, y, ...)` and symbolic constants.
public indirect enum MathASTNode: Sendable, Equatable {
    case number(Double)
    case constant(MathConstant)
    case variable(Character)
    case negate(MathASTNode)
    case binary(BinaryOp, MathASTNode, MathASTNode)
    case call(MathFunction, MathASTNode)

    public enum MathConstant: String, Sendable, Equatable {
        case pi, e

        public var numericValue: Double {
            switch self {
            case .pi: Double.pi
            case .e: M_E
            }
        }
    }

    public enum BinaryOp: Sendable, Equatable {
        case add, subtract, multiply, divide, power
    }

    public enum MathFunction: String, Sendable, Equatable {
        case sin, cos, tan, asin, acos, atan, sqrt, abs, ln, log, exp
    }

    public func evaluate(x: Double, y: Double) -> Double {
        switch self {
        case .number(let v):
            return v
        case .constant(let c):
            return c.numericValue
        case .variable(let name):
            if name == "y" { return y }
            if name == "x" { return x }
            return 0
        case .negate(let inner):
            return -inner.evaluate(x: x, y: y)
        case .binary(let op, let lhs, let rhs):
            let l = lhs.evaluate(x: x, y: y)
            let r = rhs.evaluate(x: x, y: y)
            switch op {
            case .add: return l + r
            case .subtract: return l - r
            case .multiply: return l * r
            case .divide: return l / r
            case .power: return pow(l, r)
            }
        case .call(let fn, let arg):
            return Self.evaluateCall(fn, value: arg.evaluate(x: x, y: y))
        }
    }

    public func evaluate(variables: [Character: Double]) -> Double {
        switch self {
        case .number(let v):
            return v
        case .constant(let c):
            return c.numericValue
        case .variable(let name):
            return variables[name] ?? 0
        case .negate(let inner):
            return -inner.evaluate(variables: variables)
        case .binary(let op, let lhs, let rhs):
            let l = lhs.evaluate(variables: variables)
            let r = rhs.evaluate(variables: variables)
            switch op {
            case .add: return l + r
            case .subtract: return l - r
            case .multiply: return l * r
            case .divide: return l / r
            case .power: return pow(l, r)
            }
        case .call(let fn, let arg):
            return Self.evaluateCall(fn, value: arg.evaluate(variables: variables))
        }
    }

    private static func evaluateCall(_ fn: MathFunction, value v: Double) -> Double {
        switch fn {
        case .sin: Darwin.sin(v)
        case .cos: Darwin.cos(v)
        case .tan: Darwin.tan(v)
        case .asin: Darwin.asin(v)
        case .acos: Darwin.acos(v)
        case .atan: Darwin.atan(v)
        case .sqrt: Darwin.sqrt(v)
        case .abs: Swift.abs(v)
        case .ln: Darwin.log(v)
        case .log: Darwin.log10(v)
        case .exp: Darwin.exp(v)
        }
    }

    public var freeVariables: Set<Character> {
        switch self {
        case .number, .constant:
            return []
        case .variable(let name):
            return [name]
        case .negate(let inner):
            return inner.freeVariables
        case .binary(_, let lhs, let rhs):
            return lhs.freeVariables.union(rhs.freeVariables)
        case .call(_, let arg):
            return arg.freeVariables
        }
    }

    public func dependsOn(_ variable: Character) -> Bool {
        freeVariables.contains(variable)
    }
}

/// Recursive-descent math expression parser and evaluator supporting `+ - * / ^`,
/// standard elementary functions, constants (`pi`, `e`), and implicit multiplication.
public enum MathExpressionEvaluator {
    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(Character)
        case lparen
        case rparen
    }

    public static func parseExpression(
        _ raw: String,
        allowedVariables: Set<Character> = ["x", "y"]
    ) throws -> MathASTNode {
        let tokens = try tokenize(raw, allowedVariables: allowedVariables)
        guard !tokens.isEmpty else { throw MathParseError.emptyExpression }
        var parser = Parser(tokens: tokens, allowedVariables: allowedVariables)
        let node = try parser.parseAdditive()
        if let leftover = parser.peek() {
            throw MathParseError.unexpectedToken(describe(leftover))
        }
        return node
    }

    /// Parses either `LHS = RHS` (evaluating `F(x, y) = LHS - RHS`) or an explicit expression `f(x)` (`F(x, y) = y - f(x)`).
    public static func compileEquation(_ raw: String) throws -> MathASTNode {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MathParseError.emptyExpression }

        let parts = trimmed.components(separatedBy: "=")
        if parts.count > 2 {
            throw MathParseError.multipleEqualsSigns
        }
        if parts.count == 2 {
            let lhs = try parseExpression(parts[0])
            let rhs = try parseExpression(parts[1])
            return .binary(.subtract, lhs, rhs)
        } else {
            let rhs = try parseExpression(parts[0])
            return .binary(.subtract, .variable("y"), rhs)
        }
    }

    private static func tokenize(_ raw: String, allowedVariables: Set<Character>) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(raw)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
                continue
            }

            if ch.isNumber || (ch == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                let start = i
                var hasDot = (ch == ".")
                i += 1
                while i < chars.count {
                    let c = chars[i]
                    if c.isNumber {
                        i += 1
                    } else if c == "." && !hasDot {
                        hasDot = true
                        i += 1
                    } else {
                        break
                    }
                }
                let slice = String(chars[start..<i])
                guard let value = Double(slice) else {
                    throw MathParseError.unexpectedToken(slice)
                }
                tokens.append(.number(value))
                continue
            }

            if ch.isLetter {
                let start = i
                while i < chars.count && chars[i].isLetter {
                    i += 1
                }
                let word = String(chars[start..<i]).lowercased()
                // Split adjacent single-letter variables like `xy` unless recognized word
                if isKnownWord(word, allowedVariables: allowedVariables) {
                    tokens.append(.identifier(word))
                } else {
                    for letter in word {
                        tokens.append(.identifier(String(letter)))
                    }
                }
                continue
            }

            switch ch {
            case "+", "-", "*", "/", "^":
                tokens.append(.op(ch))
                i += 1
            case "(":
                tokens.append(.lparen)
                i += 1
            case ")":
                tokens.append(.rparen)
                i += 1
            default:
                throw MathParseError.unexpectedCharacter(ch)
            }
        }

        // Insert implicit `*` where adjacent tokens denote multiplication:
        // number/identifier/')' followed by identifier/'(' or ')' followed by number
        var expanded: [Token] = []
        expanded.reserveCapacity(tokens.count)
        for idx in tokens.indices {
            let current = tokens[idx]
            if let prev = expanded.last, needsImplicitMultiply(prev: prev, next: current) {
                expanded.append(.op("*"))
            }
            expanded.append(current)
        }
        return expanded
    }

    private static func isKnownWord(_ word: String, allowedVariables: Set<Character>) -> Bool {
        if word == "pi" || word == "e" {
            return true
        }
        if word.count == 1, let ch = word.first, allowedVariables.contains(ch) {
            return true
        }
        return MathASTNode.MathFunction(rawValue: word) != nil
    }

    private static func needsImplicitMultiply(prev: Token, next: Token) -> Bool {
        let prevIsValue: Bool = switch prev {
        case .number, .rparen: true
        case .identifier(let id): MathASTNode.MathFunction(rawValue: id) == nil
        case .op, .lparen: false
        }

        let nextStartsValue: Bool = switch next {
        case .number, .identifier, .lparen: true
        case .op, .rparen: false
        }

        if !prevIsValue || !nextStartsValue {
            return false
        }
        if case .number = prev, case .number = next {
            return false
        }
        return true
    }

    private static func describe(_ token: Token) -> String {
        switch token {
        case .number(let v): String(v)
        case .identifier(let s): s
        case .op(let c): String(c)
        case .lparen: "("
        case .rparen: ")"
        }
    }

    private struct Parser {
        let tokens: [Token]
        let allowedVariables: Set<Character>
        var index: Int = 0

        init(tokens: [Token], allowedVariables: Set<Character>) {
            self.tokens = tokens
            self.allowedVariables = allowedVariables
        }

        func peek() -> Token? {
            guard index < tokens.count else { return nil }
            return tokens[index]
        }

        mutating func consume() -> Token? {
            guard index < tokens.count else { return nil }
            defer { index += 1 }
            return tokens[index]
        }

        mutating func parseAdditive() throws -> MathASTNode {
            var left = try parseMultiplicative()
            while let tok = peek(), case .op(let op) = tok, op == "+" || op == "-" {
                _ = consume()
                let right = try parseMultiplicative()
                left = .binary(op == "+" ? .add : .subtract, left, right)
            }
            return left
        }

        mutating func parseMultiplicative() throws -> MathASTNode {
            var left = try parseUnary()
            while let tok = peek(), case .op(let op) = tok, op == "*" || op == "/" {
                _ = consume()
                let right = try parseUnary()
                left = .binary(op == "*" ? .multiply : .divide, left, right)
            }
            return left
        }

        mutating func parseUnary() throws -> MathASTNode {
            if let tok = peek(), case .op(let op) = tok {
                if op == "-" {
                    _ = consume()
                    return .negate(try parseUnary())
                }
                if op == "+" {
                    _ = consume()
                    return try parseUnary()
                }
            }
            return try parsePower()
        }

        mutating func parsePower() throws -> MathASTNode {
            let base = try parsePrimary()
            if let tok = peek(), case .op("^") = tok {
                _ = consume()
                let exponent = try parseUnary()
                return .binary(.power, base, exponent)
            }
            return base
        }

        mutating func parsePrimary() throws -> MathASTNode {
            guard let tok = consume() else {
                throw MathParseError.emptyExpression
            }

            switch tok {
            case .number(let value):
                return .number(value)

            case .lparen:
                let inner = try parseAdditive()
                guard case .rparen = consume() else {
                    throw MathParseError.missingClosingParenthesis
                }
                return inner

            case .identifier(let name):
                if name == "pi" { return .constant(.pi) }
                if name == "e" { return .constant(.e) }
                if name.count == 1, let ch = name.first, allowedVariables.contains(ch) {
                    return .variable(ch)
                }

                if let fn = MathASTNode.MathFunction(rawValue: name) {
                    guard case .lparen = consume() else {
                        throw MathParseError.unexpectedToken(name)
                    }
                    let arg = try parseAdditive()
                    guard case .rparen = consume() else {
                        throw MathParseError.missingClosingParenthesis
                    }
                    return .call(fn, arg)
                }
                throw MathParseError.unknownIdentifier(name)

            case .op(let ch):
                throw MathParseError.unexpectedToken(String(ch))
            case .rparen:
                throw MathParseError.unexpectedToken(")")
            }
        }
    }
}

/// Line segment in world math coordinates extracted by Marching Squares.
public struct ContourSegment: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// 130x90 Marching Squares zero-contour extractor for implicit (`LHS = RHS`) and explicit (`y = f(x)`) curves.
public enum MarchingSquares {
    public static let defaultColumns = 130
    public static let defaultRows = 90
    private static let asymptoteJumpLimit = 80.0

    public static func extractSegments(
        ast: MathASTNode,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        columns: Int = defaultColumns,
        rows: Int = defaultRows
    ) -> [ContourSegment] {
        guard columns > 0, rows > 0 else { return [] }

        let dx = (xRange.upperBound - xRange.lowerBound) / Double(columns)
        let dy = (yRange.upperBound - yRange.lowerBound) / Double(rows)

        var grid = Array(
            repeating: Array(repeating: Double.nan, count: columns + 1),
            count: rows + 1
        )
        for r in 0...rows {
            let y = yRange.lowerBound + Double(r) * dy
            for c in 0...columns {
                let x = xRange.lowerBound + Double(c) * dx
                grid[r][c] = ast.evaluate(x: x, y: y)
            }
        }

        var segments: [ContourSegment] = []
        segments.reserveCapacity(columns * 4)

        for r in 0..<rows {
            let y0 = yRange.lowerBound + Double(r) * dy
            let y1 = y0 + dy
            for c in 0..<columns {
                let x0 = xRange.lowerBound + Double(c) * dx
                let x1 = x0 + dx

                // Corners: BL (c, r), BR (c+1, r), TR (c+1, r+1), TL (c, r+1)
                let v0 = grid[r][c]
                let v1 = grid[r][c + 1]
                let v2 = grid[r + 1][c + 1]
                let v3 = grid[r + 1][c]

                guard v0.isFinite && v1.isFinite && v2.isFinite && v3.isFinite else {
                    continue
                }

                // Skip vertical/pole discontinuities (e.g., tan(x), 1/x)
                let maxVal = max(abs(v0), abs(v1), abs(v2), abs(v3))
                let minVal = min(abs(v0), abs(v1), abs(v2), abs(v3))
                if maxVal - minVal > asymptoteJumpLimit && (v0 * v2 < 0 || v1 * v3 < 0) {
                    continue
                }

                var mask = 0
                if v0 > 0 { mask |= 1 }
                if v1 > 0 { mask |= 2 }
                if v2 > 0 { mask |= 4 }
                if v3 > 0 { mask |= 8 }

                if mask == 0 || mask == 15 { continue }

                func interp(_ a: Double, _ b: Double) -> Double {
                    let denom = a - b
                    guard abs(denom) > 1e-12 else { return 0.5 }
                    return min(1.0, max(0.0, a / denom))
                }

                // Edge midpoints:
                // 0: bottom (BL->BR), 1: right (BR->TR), 2: top (TL->TR), 3: left (BL->TL)
                let pBottom = (x0 + interp(v0, v1) * dx, y0)
                let pRight  = (x1, y0 + interp(v1, v2) * dy)
                let pTop    = (x0 + interp(v3, v2) * dx, y1)
                let pLeft   = (x0, y0 + interp(v0, v3) * dy)

                func emit(_ a: (Double, Double), _ b: (Double, Double)) {
                    segments.append(ContourSegment(x1: a.0, y1: a.1, x2: b.0, y2: b.1))
                }

                switch mask {
                case 1, 14: emit(pLeft, pBottom)
                case 2, 13: emit(pBottom, pRight)
                case 3, 12: emit(pLeft, pRight)
                case 4, 11: emit(pRight, pTop)
                case 6, 9:  emit(pBottom, pTop)
                case 7, 8:  emit(pLeft, pTop)
                case 5:
                    let center = 0.25 * (v0 + v1 + v2 + v3)
                    if center > 0 {
                        emit(pLeft, pTop)
                        emit(pBottom, pRight)
                    } else {
                        emit(pLeft, pBottom)
                        emit(pRight, pTop)
                    }
                case 10:
                    let center = 0.25 * (v0 + v1 + v2 + v3)
                    if center > 0 {
                        emit(pLeft, pBottom)
                        emit(pRight, pTop)
                    } else {
                        emit(pLeft, pTop)
                        emit(pBottom, pRight)
                    }
                default:
                    break
                }
            }
        }

        return segments
    }
}

// MARK: - Symbolic CAS, Simplification, Differentiation, Simpson Integration & Root Finding

public extension MathASTNode {
    /// Returns an algebraically simplified equivalent AST.
    func simplified() -> MathASTNode {
        var current = self
        for _ in 0..<8 {
            let next = current.simplifyPass()
            if next == current { return next }
            current = next
        }
        return current
    }

    /// Computes the symbolic derivative with respect to `variable` using sum, product,
    /// quotient, power, exponential, and chain rules, then simplifies algebraically.
    func differentiated(withRespectTo variable: Character) -> MathASTNode {
        let raw = rawDerivative(withRespectTo: variable)
        return raw.simplified()
    }

    /// Formats the AST as KaTeX-compatible LaTeX.
    func toLaTeX() -> String {
        renderLaTeX(parentPrecedence: 0)
    }

    /// Formats the AST as plain ASCII math parseable by `MathExpressionEvaluator`.
    func toPlainString() -> String {
        renderPlain(parentPrecedence: 0)
    }

    // MARK: - Symbolic Differentiation Rules

    private func rawDerivative(withRespectTo v: Character) -> MathASTNode {
        switch self {
        case .number, .constant:
            return .number(0)
        case .variable(let name):
            return .number(name == v ? 1 : 0)
        case .negate(let inner):
            return .negate(inner.rawDerivative(withRespectTo: v))
        case .binary(let op, let u, let w):
            let du = u.rawDerivative(withRespectTo: v)
            let dw = w.rawDerivative(withRespectTo: v)
            switch op {
            case .add:
                return .binary(.add, du, dw)
            case .subtract:
                return .binary(.subtract, du, dw)
            case .multiply:
                return .binary(.add, .binary(.multiply, du, w), .binary(.multiply, u, dw))
            case .divide:
                if !w.dependsOn(v) {
                    return .binary(.divide, du, w)
                }
                let num = MathASTNode.binary(.subtract, .binary(.multiply, du, w), .binary(.multiply, u, dw))
                let den = MathASTNode.binary(.power, w, .number(2))
                return .binary(.divide, num, den)
            case .power:
                let uDepends = u.dependsOn(v)
                let wDepends = w.dependsOn(v)
                if !uDepends && !wDepends {
                    return .number(0)
                } else if uDepends && !wDepends {
                    // d/dv(u^c) = c * u^(c - 1) * du
                    let expMinusOne = MathASTNode.binary(.subtract, w, .number(1))
                    let powerPart = MathASTNode.binary(.power, u, expMinusOne)
                    return .binary(.multiply, .binary(.multiply, w, powerPart), du)
                } else if !uDepends && wDepends {
                    // d/dv(a^w) = a^w * ln(a) * dw
                    let basePower = MathASTNode.binary(.power, u, w)
                    return .binary(.multiply, .binary(.multiply, basePower, .call(.ln, u)), dw)
                } else {
                    // d/dv(u^w) = u^w * (dw * ln(u) + w * du / u)
                    let basePower = MathASTNode.binary(.power, u, w)
                    let term1 = MathASTNode.binary(.multiply, dw, .call(.ln, u))
                    let term2 = MathASTNode.binary(.divide, .binary(.multiply, w, du), u)
                    return .binary(.multiply, basePower, .binary(.add, term1, term2))
                }
            }
        case .call(let fn, let u):
            let du = u.rawDerivative(withRespectTo: v)
            let outerPrime: MathASTNode
            switch fn {
            case .sin:
                outerPrime = .call(.cos, u)
            case .cos:
                outerPrime = .negate(.call(.sin, u))
            case .tan:
                let cosSq = MathASTNode.binary(.power, .call(.cos, u), .number(2))
                outerPrime = .binary(.divide, .number(1), cosSq)
            case .asin:
                let inner = MathASTNode.binary(.subtract, .number(1), .binary(.power, u, .number(2)))
                outerPrime = .binary(.divide, .number(1), .call(.sqrt, inner))
            case .acos:
                let inner = MathASTNode.binary(.subtract, .number(1), .binary(.power, u, .number(2)))
                outerPrime = .negate(.binary(.divide, .number(1), .call(.sqrt, inner)))
            case .atan:
                let inner = MathASTNode.binary(.add, .number(1), .binary(.power, u, .number(2)))
                outerPrime = .binary(.divide, .number(1), inner)
            case .sqrt:
                outerPrime = .binary(.divide, .number(1), .binary(.multiply, .number(2), .call(.sqrt, u)))
            case .abs:
                outerPrime = .binary(.divide, u, .call(.abs, u))
            case .ln:
                outerPrime = .binary(.divide, .number(1), u)
            case .log:
                outerPrime = .binary(.divide, .number(1), .binary(.multiply, u, .call(.ln, .number(10))))
            case .exp:
                outerPrime = .call(.exp, u)
            }
            return .binary(.multiply, outerPrime, du)
        }
    }

    // MARK: - Algebraic Simplification

    private func simplifyPass() -> MathASTNode {
        switch self {
        case .number(let v):
            return abs(v) < 1e-14 ? .number(0) : .number(v)
        case .constant, .variable:
            return self
        case .negate(let inner):
            let s = inner.simplifyPass()
            switch s {
            case .number(let v):
                return .number(v == 0 ? 0 : -v)
            case .negate(let doubleNeg):
                return doubleNeg
            case .binary(.subtract, let a, let b):
                return .binary(.subtract, b, a)
            default:
                return .negate(s)
            }
        case .call(let fn, let arg):
            let s = arg.simplifyPass()
            switch (fn, s) {
            case (.ln, .constant(.e)): return .number(1)
            case (.ln, .number(let v)) where abs(v - 1) < 1e-12: return .number(0)
            case (.exp, .number(let v)) where abs(v) < 1e-12: return .number(1)
            case (.sin, .number(let v)) where abs(v) < 1e-12: return .number(0)
            case (.cos, .number(let v)) where abs(v) < 1e-12: return .number(1)
            case (.tan, .number(let v)) where abs(v) < 1e-12: return .number(0)
            case (.sqrt, .number(let v)) where abs(v) < 1e-12: return .number(0)
            case (.sqrt, .number(let v)) where abs(v - 1) < 1e-12: return .number(1)
            case (.sqrt, .number(let v)) where v > 0:
                let r = Darwin.sqrt(v)
                if let intR = Self.exactInteger(r) {
                    return .number(Double(intR))
                }
                return .call(fn, s)
            case (.abs, .number(let v)):
                return .number(Swift.abs(v))
            case (.abs, .negate(let inner)):
                return .call(.abs, inner)
            default:
                return .call(fn, s)
            }
        case .binary(let op, let lhs, let rhs):
            let l = lhs.simplifyPass()
            let r = rhs.simplifyPass()
            return Self.simplifyBinary(op, l, r)
        }
    }

    private static func simplifyBinary(_ op: BinaryOp, _ l: MathASTNode, _ r: MathASTNode) -> MathASTNode {
        switch op {
        case .add:
            if case .number(let a) = l, abs(a) < 1e-14 { return r }
            if case .number(let b) = r, abs(b) < 1e-14 { return l }
            if case .number(let a) = l, case .number(let b) = r {
                return .number(a + b)
            }
            if case .negate(let inner) = r {
                return simplifyBinary(.subtract, l, inner)
            }
            if case .number(let b) = r, b < 0 {
                return simplifyBinary(.subtract, l, .number(-b))
            }
            if l == r {
                return simplifyBinary(.multiply, .number(2), l)
            }
            // Combine simple like terms: k1*u + k2*u -> (k1+k2)*u
            let (c1, base1) = splitScalarTerm(l)
            let (c2, base2) = splitScalarTerm(r)
            if base1 == base2 {
                return simplifyBinary(.multiply, .number(c1 + c2), base1)
            }
            // Fold trailing numeric constant: (x + c1) + c2
            if case .binary(.add, let x, .number(let c1)) = l, case .number(let c2) = r {
                return simplifyBinary(.add, x, .number(c1 + c2))
            }
            if case .binary(.subtract, let x, .number(let c1)) = l, case .number(let c2) = r {
                return simplifyBinary(.add, x, .number(c2 - c1))
            }
            return .binary(.add, l, r)

        case .subtract:
            if case .number(let b) = r, abs(b) < 1e-14 { return l }
            if case .number(let a) = l, abs(a) < 1e-14 { return MathASTNode.negate(r).simplifyPass() }
            if case .number(let a) = l, case .number(let b) = r {
                return .number(a - b)
            }
            if case .negate(let inner) = r {
                return simplifyBinary(.add, l, inner)
            }
            if case .number(let b) = r, b < 0 {
                return simplifyBinary(.add, l, .number(-b))
            }
            if l == r {
                return .number(0)
            }
            let (c1, base1) = splitScalarTerm(l)
            let (c2, base2) = splitScalarTerm(r)
            if base1 == base2 {
                return simplifyBinary(.multiply, .number(c1 - c2), base1)
            }
            if case .binary(.add, let x, .number(let c1)) = l, case .number(let c2) = r {
                return simplifyBinary(.add, x, .number(c1 - c2))
            }
            if case .binary(.subtract, let x, .number(let c1)) = l, case .number(let c2) = r {
                return simplifyBinary(.subtract, x, .number(c1 + c2))
            }
            return .binary(.subtract, l, r)

        case .multiply:
            if case .number(let a) = l {
                if abs(a) < 1e-14 { return .number(0) }
                if abs(a - 1) < 1e-14 { return r }
                if abs(a + 1) < 1e-14 { return MathASTNode.negate(r).simplifyPass() }
                if case .number(let b) = r { return .number(a * b) }
                if case .negate(let inner) = r {
                    return simplifyBinary(.multiply, .number(-a), inner)
                }
                if case .binary(.multiply, .number(let c), let rest) = r {
                    return simplifyBinary(.multiply, .number(a * c), rest)
                }
                if case .binary(.divide, let num, let den) = r {
                    return simplifyBinary(.divide, simplifyBinary(.multiply, l, num), den)
                }
            }
            if case .number(let b) = r {
                if abs(b) < 1e-14 { return .number(0) }
                if abs(b - 1) < 1e-14 { return l }
                if abs(b + 1) < 1e-14 { return MathASTNode.negate(l).simplifyPass() }
                // Put scalar coefficients on the left: (expr * c) -> (c * expr)
                return simplifyBinary(.multiply, .number(b), l)
            }
            if case .negate(let a) = l, case .negate(let b) = r {
                return simplifyBinary(.multiply, a, b)
            }
            if case .negate(let a) = l {
                return MathASTNode.negate(simplifyBinary(.multiply, a, r)).simplifyPass()
            }
            if case .negate(let b) = r {
                return MathASTNode.negate(simplifyBinary(.multiply, l, b)).simplifyPass()
            }
            if case .binary(.divide, let n, let d) = l {
                return simplifyBinary(.divide, simplifyBinary(.multiply, n, r), d)
            }
            if case .binary(.divide, let n, let d) = r {
                return simplifyBinary(.divide, simplifyBinary(.multiply, l, n), d)
            }
            if l == r {
                return .binary(.power, l, .number(2))
            }
            if case .binary(.power, let base, .number(let exp)) = r, base == l {
                return simplifyBinary(.power, base, .number(exp + 1))
            }
            if case .binary(.power, let base, .number(let exp)) = l, base == r {
                return simplifyBinary(.power, base, .number(exp + 1))
            }
            return .binary(.multiply, l, r)

        case .divide:
            if case .number(let a) = l, abs(a) < 1e-14 {
                return .number(0)
            }
            if case .number(let b) = r {
                if abs(b - 1) < 1e-14 { return l }
                if abs(b + 1) < 1e-14 { return MathASTNode.negate(l).simplifyPass() }
                if case .number(let a) = l, b != 0 {
                    if let intA = exactInteger(a), let intB = exactInteger(b) {
                        if intA % intB == 0 {
                            return .number(Double(intA / intB))
                        }
                        let g = gcd(abs(intA), abs(intB))
                        let sign = (intA < 0) != (intB < 0) ? -1 : 1
                        let num = abs(intA) / g
                        let den = abs(intB) / g
                        let frac = MathASTNode.binary(.divide, .number(Double(num)), .number(Double(den)))
                        return sign < 0 ? .negate(frac) : frac
                    }
                    return .number(a / b)
                }
                // (c * expr) / b
                if case .binary(.multiply, .number(let c), let rest) = l,
                   let intC = exactInteger(c), let intB = exactInteger(b), intB != 0 {
                    if intC % intB == 0 {
                        return simplifyBinary(.multiply, .number(Double(intC / intB)), rest)
                    }
                    let g = gcd(abs(intC), abs(intB))
                    if g > 1 {
                        let newNum = simplifyBinary(.multiply, .number(Double(intC / g)), rest)
                        return .binary(.divide, newNum, .number(Double(intB / g)))
                    }
                }
            }
            if l == r {
                return .number(1)
            }
            return .binary(.divide, l, r)

        case .power:
            if case .number(let b) = r {
                if abs(b) < 1e-14 { return .number(1) }
                if abs(b - 1) < 1e-14 { return l }
                if case .number(let a) = l {
                    return .number(pow(a, b))
                }
                if case .binary(.power, let innerBase, .number(let m)) = l {
                    return simplifyBinary(.power, innerBase, .number(m * b))
                }
            }
            if case .number(let a) = l {
                if abs(a) < 1e-14 { return .number(0) }
                if abs(a - 1) < 1e-14 { return .number(1) }
            }
            return .binary(.power, l, r)
        }
    }

    private static func splitScalarTerm(_ node: MathASTNode) -> (Double, MathASTNode) {
        switch node {
        case .negate(let inner):
            let (c, base) = splitScalarTerm(inner)
            return (-c, base)
        case .binary(.multiply, .number(let c), let rest):
            return (c, rest)
        default:
            return (1, node)
        }
    }

    private static func exactInteger(_ v: Double) -> Int64? {
        guard v.isFinite, abs(v) < 1e12 else { return nil }
        let r = v.rounded()
        if abs(v - r) < 1e-12 {
            return Int64(r)
        }
        return nil
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a
        var y = b
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return Swift.max(1, x)
    }

    // MARK: - Formatting (LaTeX & Plain)

    private func renderLaTeX(parentPrecedence: Int) -> String {
        switch self {
        case .number(let v):
            return MathExpressionEvaluator.formatNumber(v)
        case .constant(.pi):
            return "\\pi"
        case .constant(.e):
            return "e"
        case .variable(let name):
            return String(name)
        case .negate(let inner):
            let innerStr: String
            switch inner {
            case .binary(.add, _, _), .binary(.subtract, _, _), .negate:
                innerStr = "\\left(\(inner.renderLaTeX(parentPrecedence: 0))\\right)"
            default:
                innerStr = inner.renderLaTeX(parentPrecedence: 3)
            }
            let raw = "-\(innerStr)"
            return parentPrecedence > 2 ? "\\left(\(raw)\\right)" : raw
        case .call(let fn, let arg):
            let argTex = arg.renderLaTeX(parentPrecedence: 0)
            switch fn {
            case .sqrt: return "\\sqrt{\(argTex)}"
            case .abs: return "\\left|\(argTex)\\right|"
            case .sin: return "\\sin(\(argTex))"
            case .cos: return "\\cos(\(argTex))"
            case .tan: return "\\tan(\(argTex))"
            case .asin: return "\\arcsin(\(argTex))"
            case .acos: return "\\arccos(\(argTex))"
            case .atan: return "\\arctan(\(argTex))"
            case .ln: return "\\ln(\(argTex))"
            case .log: return "\\log_{10}(\(argTex))"
            case .exp: return "\\exp(\(argTex))"
            }
        case .binary(let op, let lhs, let rhs):
            switch op {
            case .add:
                let s = "\(lhs.renderLaTeX(parentPrecedence: 1)) + \(rhs.renderLaTeX(parentPrecedence: 1))"
                return parentPrecedence > 1 ? "\\left(\(s)\\right)" : s
            case .subtract:
                let s = "\(lhs.renderLaTeX(parentPrecedence: 1)) - \(rhs.renderLaTeX(parentPrecedence: 2))"
                return parentPrecedence > 1 ? "\\left(\(s)\\right)" : s
            case .multiply:
                let lStr = lhs.renderLaTeX(parentPrecedence: 2)
                let rStr = rhs.renderLaTeX(parentPrecedence: 2)
                let needsDot: Bool = switch rhs {
                case .number, .negate: true
                default: false
                }
                let sep = needsDot ? " \\cdot " : (Self.startsWithLatexCommand(rStr) ? " " : "")
                let s = "\(lStr)\(sep)\(rStr)"
                return parentPrecedence > 2 ? "\\left(\(s)\\right)" : s
            case .divide:
                let num = lhs.renderLaTeX(parentPrecedence: 0)
                let den = rhs.renderLaTeX(parentPrecedence: 0)
                return "\\frac{\(num)}{\(den)}"
            case .power:
                let baseStr: String = switch lhs {
                case .number(let v) where v >= 0:
                    MathExpressionEvaluator.formatNumber(v)
                case .constant, .variable:
                    lhs.renderLaTeX(parentPrecedence: 4)
                default:
                    "\\left(\(lhs.renderLaTeX(parentPrecedence: 0))\\right)"
                }
                let expStr = rhs.renderLaTeX(parentPrecedence: 0)
                return "\(baseStr)^{\(expStr)}"
            }
        }
    }

    private static func startsWithLatexCommand(_ s: String) -> Bool {
        s.hasPrefix("\\")
    }

    private func renderPlain(parentPrecedence: Int) -> String {
        switch self {
        case .number(let v):
            return MathExpressionEvaluator.formatNumber(v)
        case .constant(.pi):
            return "pi"
        case .constant(.e):
            return "e"
        case .variable(let name):
            return String(name)
        case .negate(let inner):
            let innerStr = inner.renderPlain(parentPrecedence: 3)
            let raw = "-\(innerStr)"
            return parentPrecedence > 2 ? "(\(raw))" : raw
        case .call(let fn, let arg):
            return "\(fn.rawValue)(\(arg.renderPlain(parentPrecedence: 0)))"
        case .binary(let op, let lhs, let rhs):
            switch op {
            case .add:
                let s = "\(lhs.renderPlain(parentPrecedence: 1)) + \(rhs.renderPlain(parentPrecedence: 1))"
                return parentPrecedence > 1 ? "(\(s))" : s
            case .subtract:
                let s = "\(lhs.renderPlain(parentPrecedence: 1)) - \(rhs.renderPlain(parentPrecedence: 2))"
                return parentPrecedence > 1 ? "(\(s))" : s
            case .multiply:
                let s = "\(lhs.renderPlain(parentPrecedence: 2)) * \(rhs.renderPlain(parentPrecedence: 2))"
                return parentPrecedence > 2 ? "(\(s))" : s
            case .divide:
                let s = "\(lhs.renderPlain(parentPrecedence: 2)) / \(rhs.renderPlain(parentPrecedence: 3))"
                return parentPrecedence > 2 ? "(\(s))" : s
            case .power:
                let baseStr: String = switch lhs {
                case .number(let v) where v >= 0:
                    MathExpressionEvaluator.formatNumber(v)
                case .constant, .variable:
                    lhs.renderPlain(parentPrecedence: 4)
                default:
                    "(\(lhs.renderPlain(parentPrecedence: 0)))"
                }
                let expStr = rhs.renderPlain(parentPrecedence: 3)
                return "\(baseStr)^\(expStr)"
            }
        }
    }
}

public extension MathExpressionEvaluator {
    static func formatNumber(_ value: Double) -> String {
        if abs(value) < 1e-12 { return "0" }
        let rounded = value.rounded()
        if abs(value - rounded) < 1e-9 && abs(rounded) < 1e12 {
            return String(Int64(rounded))
        }
        var formatted = String(format: "%.6f", value)
        while formatted.contains(".") && (formatted.hasSuffix("0") || formatted.hasSuffix(".")) {
            if formatted.hasSuffix(".") {
                formatted.removeLast()
                break
            }
            formatted.removeLast()
        }
        return formatted
    }

    /// Parses and symbolically differentiates `raw` with respect to `variable`.
    static func differentiate(_ raw: String, withRespectTo variable: Character = "x") throws -> MathASTNode {
        let ast = try parseExpression(raw, allowedVariables: ["x", "y", variable])
        return ast.differentiated(withRespectTo: variable)
    }

    /// Numerically integrates `raw` over `[a, b]` using Composite Simpson's rule.
    static func integrate(
        _ raw: String,
        variable: Character = "x",
        from a: Double,
        to b: Double,
        subintervals: Int = 1000
    ) throws -> Double {
        let ast = try parseExpression(raw, allowedVariables: ["x", "y", variable])
        return try integrate(ast, variable: variable, from: a, to: b, subintervals: subintervals)
    }

    static func integrate(
        _ ast: MathASTNode,
        variable: Character = "x",
        from a: Double,
        to b: Double,
        subintervals: Int = 1000
    ) throws -> Double {
        guard a.isFinite, b.isFinite else {
            throw MathCASError.invalidBounds("Integration bounds must be finite.")
        }
        if abs(a - b) < 1e-14 { return 0 }
        let evenN = max(2, subintervals % 2 == 0 ? subintervals : subintervals + 1)
        let h = (b - a) / Double(evenN)

        func eval(_ t: Double) throws -> Double {
            let v = ast.evaluate(variables: [variable: t])
            guard v.isFinite else { throw MathCASError.nonFiniteResult }
            return v
        }

        var sum = try eval(a) + eval(b)
        for i in 1..<evenN {
            let x = a + Double(i) * h
            let weight = (i % 2 == 0) ? 2.0 : 4.0
            sum += weight * (try eval(x))
        }
        let result = (h / 3.0) * sum
        guard result.isFinite else { throw MathCASError.nonFiniteResult }
        return abs(result) < 1e-12 ? 0 : result
    }

    /// Numerically finds real roots of `raw` (either `lhs = rhs` or `expr`) in `range`.
    static func solve(
        _ raw: String,
        variable: Character = "x",
        range: ClosedRange<Double> = -100...100
    ) throws -> [Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MathParseError.emptyExpression }
        let allowed: Set<Character> = ["x", "y", variable]

        let targetAST: MathASTNode
        let parts = trimmed.components(separatedBy: "=")
        if parts.count > 2 {
            throw MathParseError.multipleEqualsSigns
        } else if parts.count == 2 {
            let lhs = try parseExpression(parts[0], allowedVariables: allowed)
            let rhs = try parseExpression(parts[1], allowedVariables: allowed)
            targetAST = .binary(.subtract, lhs, rhs)
        } else {
            targetAST = try parseExpression(parts[0], allowedVariables: allowed)
        }

        return solve(targetAST, variable: variable, range: range)
    }

    static func solve(
        _ ast: MathASTNode,
        variable: Character = "x",
        range: ClosedRange<Double> = -100...100
    ) -> [Double] {
        func f(_ t: Double) -> Double {
            ast.evaluate(variables: [variable: t])
        }

        // Build non-uniform sample grid (finer near [-10, 10])
        var samples: [Double] = []
        let outerLower = range.lowerBound
        let outerUpper = range.upperBound
        let fineLower = max(outerLower, -10.0)
        let fineUpper = min(outerUpper, 10.0)

        if outerLower < fineLower {
            let n = 400
            let step = (fineLower - outerLower) / Double(n)
            for i in 0..<n { samples.append(outerLower + Double(i) * step) }
        }
        if fineLower < fineUpper {
            let n = 1200
            let step = (fineUpper - fineLower) / Double(n)
            for i in 0...n { samples.append(fineLower + Double(i) * step) }
        }
        if fineUpper < outerUpper {
            let n = 400
            let step = (outerUpper - fineUpper) / Double(n)
            for i in 1...n { samples.append(fineUpper + Double(i) * step) }
        }
        if !samples.contains(where: { abs($0) < 1e-12 }) && range.contains(0) {
            samples.append(0)
            samples.sort()
        }

        var roots: [Double] = []

        func appendRoot(_ candidate: Double) {
            let cleaned = abs(candidate) < 1e-9 ? 0.0 : candidate
            let val = f(cleaned)
            guard val.isFinite, abs(val) < 1e-5 else { return }
            if !roots.contains(where: { abs($0 - cleaned) < 1e-4 }) {
                roots.append(cleaned)
            }
        }

        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            let fa = f(a)
            let fb = f(b)
            guard fa.isFinite, fb.isFinite else { continue }

            if abs(fa) < 1e-10 {
                appendRoot(a)
                continue
            }
            if abs(fb) < 1e-10 {
                appendRoot(b)
                continue
            }

            // Sign change bracket (skip poles where magnitude jumps sharply)
            if fa * fb < 0 {
                if abs(fa - fb) > 100.0 && (abs(fa) > 20.0 || abs(fb) > 20.0) {
                    continue
                }
                if let root = refineBracketRoot(f: f, a: a, b: b) {
                    appendRoot(root)
                }
            }
        }

        // Check local minima of |f(x)| for even-multiplicity (tangent) roots
        if samples.count >= 3 {
            for i in 1..<(samples.count - 1) {
                let x0 = samples[i - 1]
                let x1 = samples[i]
                let x2 = samples[i + 1]
                let y0 = abs(f(x0))
                let y1 = abs(f(x1))
                let y2 = abs(f(x2))
                guard y0.isFinite, y1.isFinite, y2.isFinite else { continue }
                if y1 < y0 && y1 < y2 && y1 < 0.05 {
                    if let root = refineMinimumRoot(f: f, a: x0, b: x2) {
                        appendRoot(root)
                    }
                }
            }
        }

        return roots.sorted()
    }

    private static func refineBracketRoot(f: (Double) -> Double, a: Double, b: Double) -> Double? {
        var lo = a
        var hi = b
        var flo = f(lo)
        var fhi = f(hi)
        guard flo.isFinite, fhi.isFinite else { return nil }

        for _ in 0..<64 {
            let mid = 0.5 * (lo + hi)
            let fmid = f(mid)
            if !fmid.isFinite { return nil }
            if abs(fmid) < 1e-12 || abs(hi - lo) < 1e-12 {
                return mid
            }
            if flo * fmid <= 0 {
                hi = mid
                fhi = fmid
            } else {
                lo = mid
                flo = fmid
            }
        }
        let candidate = 0.5 * (lo + hi)
        return abs(f(candidate)) < 1e-5 ? candidate : nil
    }

    private static func refineMinimumRoot(f: (Double) -> Double, a: Double, b: Double) -> Double? {
        var lo = a
        var hi = b
        let phi = (Darwin.sqrt(5.0) - 1.0) / 2.0
        var c = hi - phi * (hi - lo)
        var d = lo + phi * (hi - lo)
        var fc = abs(f(c))
        var fd = abs(f(d))

        for _ in 0..<60 {
            if abs(hi - lo) < 1e-12 { break }
            if fc < fd {
                hi = d
                d = c
                fd = fc
                c = hi - phi * (hi - lo)
                fc = abs(f(c))
            } else {
                lo = c
                c = d
                fc = fd
                d = lo + phi * (hi - lo)
                fd = abs(f(d))
            }
        }
        let best = 0.5 * (lo + hi)
        let val = f(best)
        return (val.isFinite && abs(val) < 1e-5) ? best : nil
    }

    // MARK: - Unified CAS Console Evaluator

    static func evaluateCAS(_ raw: String) throws -> CASCommandResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MathParseError.emptyExpression }

        if let args = extractCommandArguments(trimmed, command: "diff") {
            guard args.count == 1 || args.count == 2 else {
                throw MathCASError.invalidCommandSyntax("Use diff(expr, var), e.g. diff(x^3, x).")
            }
            let varChar = try parseVariableArgument(args.count == 2 ? args[1] : "x")
            let exprNode = try parseExpression(args[0], allowedVariables: ["x", "y", varChar])
            let deriv = exprNode.differentiated(withRespectTo: varChar)
            let inputLatex = "\\frac{d}{d\(varChar)}\\left(\(exprNode.toLaTeX())\\right)"
            let plottable: String? = deriv.freeVariables.subtracting(["x"]).isEmpty
                ? "y = \(deriv.toPlainString())"
                : nil
            return CASCommandResult(
                inputLatex: inputLatex,
                outputLatex: deriv.toLaTeX(),
                plottableExpression: plottable,
                shouldAutoPlot: false
            )
        }

        if let args = extractCommandArguments(trimmed, command: "integrate") {
            let varChar: Character
            let exprRaw: String
            let aRaw: String
            let bRaw: String
            if args.count == 4 {
                exprRaw = args[0]
                varChar = try parseVariableArgument(args[1])
                aRaw = args[2]
                bRaw = args[3]
            } else if args.count == 3 {
                exprRaw = args[0]
                varChar = "x"
                aRaw = args[1]
                bRaw = args[2]
            } else {
                throw MathCASError.invalidCommandSyntax("Use integrate(expr, var, a, b), e.g. integrate(sin(x), x, 0, pi).")
            }

            let exprNode = try parseExpression(exprRaw, allowedVariables: ["x", "y", varChar])
            let aNode = try parseExpression(aRaw, allowedVariables: [])
            let bNode = try parseExpression(bRaw, allowedVariables: [])
            let aVal = aNode.evaluate(x: 0, y: 0)
            let bVal = bNode.evaluate(x: 0, y: 0)
            let integral = try integrate(exprNode, variable: varChar, from: aVal, to: bVal)
            let inputLatex = "\\int_{\(aNode.toLaTeX())}^{\(bNode.toLaTeX())} \(exprNode.toLaTeX())\\,d\(varChar)"
            return CASCommandResult(
                inputLatex: inputLatex,
                outputLatex: formatNumber(integral)
            )
        }

        if let args = extractCommandArguments(trimmed, command: "solve") {
            guard args.count == 1 || args.count == 2 else {
                throw MathCASError.invalidCommandSyntax("Use solve(lhs = rhs, var), e.g. solve(x^2 = 4, x).")
            }
            let varChar = try parseVariableArgument(args.count == 2 ? args[1] : "x")
            let allowed: Set<Character> = ["x", "y", varChar]
            let eqParts = args[0].components(separatedBy: "=")
            if eqParts.count > 2 {
                throw MathParseError.multipleEqualsSigns
            }
            let inputLatex: String
            if eqParts.count == 2 {
                let lhs = try parseExpression(eqParts[0], allowedVariables: allowed)
                let rhs = try parseExpression(eqParts[1], allowedVariables: allowed)
                inputLatex = "\(lhs.toLaTeX()) = \(rhs.toLaTeX())"
            } else {
                let lhs = try parseExpression(eqParts[0], allowedVariables: allowed)
                inputLatex = "\(lhs.toLaTeX()) = 0"
            }
            let roots = try solve(args[0], variable: varChar)
            let outputLatex: String
            if roots.isEmpty {
                outputLatex = "\\text{No real roots in }[-100, 100]"
            } else if roots.count == 1 {
                outputLatex = "\(varChar) \\approx \(formatNumber(roots[0]))"
            } else {
                let formatted = roots.map { formatNumber($0) }.joined(separator: ",\\; ")
                outputLatex = "\(varChar) \\in \\{\(formatted)\\}"
            }
            return CASCommandResult(inputLatex: inputLatex, outputLatex: outputLatex)
        }

        if let args = extractCommandArguments(trimmed, command: "simplify") {
            guard args.count == 1 else {
                throw MathCASError.invalidCommandSyntax("Use simplify(expr).")
            }
            let node = try parseExpression(args[0])
            let simp = node.simplified()
            return CASCommandResult(inputLatex: node.toLaTeX(), outputLatex: simp.toLaTeX())
        }

        // Equation containing '=' -> plot and log
        if trimmed.contains("=") {
            let parts = trimmed.components(separatedBy: "=")
            if parts.count > 2 {
                throw MathParseError.multipleEqualsSigns
            }
            let lhs = try parseExpression(parts[0])
            let rhs = try parseExpression(parts[1])
            _ = try compileEquation(trimmed)
            let latex = "\(lhs.toLaTeX()) = \(rhs.toLaTeX())"
            return CASCommandResult(
                inputLatex: latex,
                outputLatex: latex,
                plottableExpression: trimmed,
                shouldAutoPlot: true
            )
        }

        // General expression or arithmetic
        let node = try parseExpression(trimmed)
        if node.freeVariables.isEmpty {
            let value = node.evaluate(x: 0, y: 0)
            guard value.isFinite else { throw MathCASError.nonFiniteResult }
            return CASCommandResult(
                inputLatex: node.toLaTeX(),
                outputLatex: formatNumber(value)
            )
        } else {
            let simp = node.simplified()
            let plottable: String? = simp.freeVariables.subtracting(["x"]).isEmpty
                ? "y = \(simp.toPlainString())"
                : nil
            return CASCommandResult(
                inputLatex: node.toLaTeX(),
                outputLatex: simp.toLaTeX(),
                plottableExpression: plottable,
                shouldAutoPlot: false
            )
        }
    }

    private static func extractCommandArguments(_ raw: String, command: String) -> [String]? {
        let lower = raw.lowercased()
        guard lower.hasPrefix(command) else { return nil }
        let afterName = raw.dropFirst(command.count).drop(while: { $0.isWhitespace })
        guard afterName.first == "(", afterName.last == ")" else { return nil }
        let inner = String(afterName.dropFirst().dropLast())
        return splitTopLevelCommaArguments(inner)
    }

    private static func splitTopLevelCommaArguments(_ inner: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        for ch in inner {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }

            if ch == "," && depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty || !result.isEmpty {
            result.append(tail)
        }
        return result
    }

    private static func parseVariableArgument(_ raw: String) throws -> Character {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 1, let ch = trimmed.first, ch.isLetter, trimmed != "e" else {
            throw MathCASError.invalidVariable(raw)
        }
        return ch
    }
}
