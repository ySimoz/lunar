import Foundation

/// Fast, synchronous pure-Swift LaTeX-to-Unicode formatter for dense list and inspector rows.
/// Avoids spawning `WKWebView` instances for non-focal list items.
public enum MathPlainText {
    private static let commandMap: [String: String] = [
        // Calculus & Analysis
        "int": "∫",
        "iint": "∬",
        "iiint": "∭",
        "oint": "∮",
        "sum": "∑",
        "prod": "∏",
        "lim": "lim",
        "infty": "∞",
        "partial": "∂",
        "nabla": "∇",

        // Comparisons & Equivalence
        "le": "≤",
        "leq": "≤",
        "ge": "≥",
        "geq": "≥",
        "neq": "≠",
        "ne": "≠",
        "approx": "≈",
        "equiv": "≡",
        "sim": "∼",
        "simeq": "≃",
        "cong": "≅",
        "propto": "∝",

        // Arrows & Logic
        "implies": "⇒",
        "Rightarrow": "⇒",
        "iff": "⇔",
        "Leftrightarrow": "⇔",
        "to": "→",
        "rightarrow": "→",
        "leftarrow": "←",
        "Leftarrow": "⇐",
        "mapsto": "↦",
        "forall": "∀",
        "exists": "∃",
        "nexists": "∄",
        "land": "∧",
        "wedge": "∧",
        "lor": "∨",
        "vee": "∨",
        "neg": "¬",
        "lnot": "¬",

        // Sets
        "in": "∈",
        "notin": "∉",
        "subseteq": "⊆",
        "subset": "⊂",
        "supseteq": "⊇",
        "supset": "⊃",
        "cup": "∪",
        "cap": "∩",
        "setminus": "∖",
        "emptyset": "∅",
        "varnothing": "∅",

        // Operators & Punctuation
        "cdot": "·",
        "times": "×",
        "div": "÷",
        "pm": "±",
        "mp": "∓",
        "circ": "∘",
        "oplus": "⊕",
        "otimes": "⊗",
        "dots": "…",
        "ldots": "…",
        "cdots": "⋯",
        "vdots": "⋮",
        "angle": "∠",
        "perp": "⊥",
        "parallel": "∥",

        // Standard Functions
        "sin": "sin",
        "cos": "cos",
        "tan": "tan",
        "csc": "csc",
        "sec": "sec",
        "cot": "cot",
        "arcsin": "arcsin",
        "arccos": "arccos",
        "arctan": "arctan",
        "sinh": "sinh",
        "cosh": "cosh",
        "tanh": "tanh",
        "ln": "ln",
        "log": "log",
        "exp": "exp",
        "sup": "sup",
        "inf": "inf",
        "max": "max",
        "min": "min",
        "det": "det",
        "dim": "dim",
        "ker": "ker",
        "deg": "deg",
        "gcd": "gcd",
        "arg": "arg",
        "Re": "Re",
        "Im": "Im",

        // Greek lowercase
        "alpha": "α",
        "beta": "β",
        "gamma": "γ",
        "delta": "δ",
        "epsilon": "ε",
        "varepsilon": "ε",
        "zeta": "ζ",
        "eta": "η",
        "theta": "θ",
        "vartheta": "ϑ",
        "iota": "ι",
        "kappa": "κ",
        "lambda": "λ",
        "mu": "μ",
        "nu": "ν",
        "xi": "ξ",
        "pi": "π",
        "varpi": "ϖ",
        "rho": "ρ",
        "varrho": "ϱ",
        "sigma": "σ",
        "varsigma": "ς",
        "tau": "τ",
        "upsilon": "υ",
        "phi": "φ",
        "varphi": "φ",
        "chi": "χ",
        "psi": "ψ",
        "omega": "ω",

        // Greek uppercase
        "Gamma": "Γ",
        "Delta": "Δ",
        "Theta": "Θ",
        "Lambda": "Λ",
        "Xi": "Ξ",
        "Pi": "Π",
        "Sigma": "Σ",
        "Upsilon": "Υ",
        "Phi": "Φ",
        "Psi": "Ψ",
        "Omega": "Ω"
    ]

    private static let blackboardMap: [String: String] = [
        "R": "ℝ",
        "N": "ℕ",
        "Z": "ℤ",
        "C": "ℂ",
        "Q": "ℚ",
        "F": "𝔽",
        "P": "ℙ",
        "E": "𝔼"
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "(": "₍", ")": "₎",
        "n": "ₙ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ"
    ]

    private static let unwrapCommands: Set<String> = [
        "text", "textbf", "textit", "textrm", "mathrm", "mathbf", "mathit",
        "mathsf", "mathtt", "operatorname", "mathcal", "mathscr", "mathfrak", "boldsymbol"
    ]

    private static let stripCommands: Set<String> = [
        "left", "right", "big", "Big", "bigg", "Bigg", "displaystyle", "textstyle",
        "scriptstyle", "nolimits", "limits"
    ]

    public static func format(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let strippedImages = stripDataURIImages(trimmed)
        let chars = Array(strippedImages)
        var formatted = parse(chars, start: 0, end: chars.count)
        formatted = formatted
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")

        // Collapse whitespace/newlines into single spaces
        let components = formatted.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }

    private static func stripDataURIImages(_ text: String) -> String {
        guard text.contains("data:image/"),
              let regex = try? NSRegularExpression(
                  pattern: #"!\[([^\]]*)\]\(data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+\)"#,
                  options: []
              ) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let altRange = match.range(at: 1)
            let alt = altRange.location != NSNotFound
                ? ns.substring(with: altRange).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let label = alt.isEmpty ? "[Graph]" : "[\(alt)]"
            mutable.replaceCharacters(in: match.range, with: label)
        }
        return mutable as String
    }

    private static func parse(_ chars: [Character], start: Int, end: Int) -> String {
        var out = ""
        var i = start

        while i < end {
            let ch = chars[i]

            // Strip $ and $$ delimiters
            if ch == "$" {
                i += 1
                if i < end && chars[i] == "$" {
                    i += 1
                }
                continue
            }

            // Superscript ^
            if ch == "^" {
                i += 1
                if i < end, chars[i] == "{" {
                    let (group, nextIdx) = readBraced(chars, from: i, limit: end)
                    i = nextIdx
                    let inner = formatGroup(group)
                    out.append(toSuperscript(inner) ?? "^(\(inner))")
                } else if i < end {
                    let nextCh = chars[i]
                    i += 1
                    if let sup = superscriptMap[nextCh] {
                        out.append(sup)
                    } else {
                        out.append("^")
                        out.append(nextCh)
                    }
                }
                continue
            }

            // Subscript _
            if ch == "_" {
                i += 1
                if i < end, chars[i] == "{" {
                    let (group, nextIdx) = readBraced(chars, from: i, limit: end)
                    i = nextIdx
                    let inner = formatGroup(group)
                    out.append(toSubscript(inner) ?? "_(\(inner))")
                } else if i < end {
                    let nextCh = chars[i]
                    i += 1
                    if let sub = subscriptMap[nextCh] {
                        out.append(sub)
                    } else {
                        out.append("_")
                        out.append(nextCh)
                    }
                }
                continue
            }

            // Backslash command / delimiter
            if ch == "\\" {
                i += 1
                guard i < end else { break }
                let next = chars[i]

                // Delimiters \( \), \[ \], \{ \}, \\ , spacing \, \; \! \:
                switch next {
                case "(", ")", "[", "]":
                    i += 1
                    continue
                case "{", "}":
                    out.append(next)
                    i += 1
                    continue
                case "\\":
                    out.append(" ")
                    i += 1
                    continue
                case ",", ";", "!", ":", " ":
                    if next != "!" { out.append(" ") }
                    i += 1
                    continue
                default:
                    break
                }

                // Read alphabetic command name
                if next.isLetter {
                    let cmdStart = i
                    while i < end && chars[i].isLetter {
                        i += 1
                    }
                    let cmd = String(chars[cmdStart..<i])

                    if cmd == "frac" || cmd == "dfrac" || cmd == "tfrac" {
                        let (numRaw, afterNum) = readArgument(chars, from: i, limit: end)
                        let (denRaw, afterDen) = readArgument(chars, from: afterNum, limit: end)
                        i = afterDen
                        let num = formatGroup(numRaw)
                        let den = formatGroup(denRaw)
                        out.append("(\(num))/(\(den))")
                        continue
                    }

                    if cmd == "sqrt" {
                        var cursor = skipSpaces(chars, from: i, limit: end)
                        if cursor < end && chars[cursor] == "[" {
                            while cursor < end && chars[cursor] != "]" {
                                cursor += 1
                            }
                            if cursor < end { cursor += 1 }
                        }
                        let (radicandRaw, afterRad) = readArgument(chars, from: cursor, limit: end)
                        i = afterRad
                        let radicand = formatGroup(radicandRaw)
                        out.append("√(\(radicand))")
                        continue
                    }

                    if cmd == "mathbb" {
                        let (argRaw, afterArg) = readArgument(chars, from: i, limit: end)
                        i = afterArg
                        let inner = formatGroup(argRaw)
                        if let mapped = blackboardMap[inner] {
                            out.append(mapped)
                        } else {
                            out.append(inner)
                        }
                        continue
                    }

                    if unwrapCommands.contains(cmd) {
                        let (argRaw, afterArg) = readArgument(chars, from: i, limit: end)
                        i = afterArg
                        out.append(formatGroup(argRaw))
                        continue
                    }

                    if stripCommands.contains(cmd) {
                        continue
                    }

                    if cmd == "quad" || cmd == "qquad" {
                        out.append(" ")
                        continue
                    }

                    if let symbol = commandMap[cmd] {
                        // Add separating space before/after word-like commands if needed
                        let isWord = symbol.allSatisfy(\.isLetter)
                        if isWord, let last = out.last, last.isLetter || last.isNumber {
                            out.append(" ")
                        }
                        out.append(symbol)
                        if isWord, i < end, chars[i].isLetter {
                            out.append(" ")
                        }
                        continue
                    }

                    // Unknown command: emit name cleanly without backslash
                    out.append(cmd)
                    continue
                } else {
                    out.append(next)
                    i += 1
                    continue
                }
            }

            // Strip bare grouping braces
            if ch == "{" || ch == "}" {
                i += 1
                continue
            }

            out.append(ch)
            i += 1
        }

        return out
    }

    private static func formatGroup(_ raw: [Character]) -> String {
        parse(raw, start: 0, end: raw.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipSpaces(_ chars: [Character], from idx: Int, limit: Int) -> Int {
        var i = idx
        while i < limit && chars[i].isWhitespace {
            i += 1
        }
        return i
    }

    private static func readBraced(_ chars: [Character], from idx: Int, limit: Int) -> ([Character], Int) {
        guard idx < limit, chars[idx] == "{" else { return ([], idx) }
        var depth = 0
        var i = idx
        let contentStart = idx + 1
        while i < limit {
            let ch = chars[i]
            if ch == "\\" && i + 1 < limit {
                i += 2
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return (Array(chars[contentStart..<i]), i + 1)
                }
            }
            i += 1
        }
        return (Array(chars[contentStart..<limit]), limit)
    }

    private static func readArgument(_ chars: [Character], from idx: Int, limit: Int) -> ([Character], Int) {
        let i = skipSpaces(chars, from: idx, limit: limit)
        guard i < limit else { return ([], i) }
        if chars[i] == "{" {
            return readBraced(chars, from: i, limit: limit)
        }
        return ([chars[i]], i + 1)
    }

    private static func toSuperscript(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var mapped = ""
        for ch in text {
            guard let s = superscriptMap[ch] else { return nil }
            mapped.append(s)
        }
        return mapped
    }

    private static func toSubscript(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        var mapped = ""
        for ch in text {
            guard let s = subscriptMap[ch] else { return nil }
            mapped.append(s)
        }
        return mapped
    }
}
