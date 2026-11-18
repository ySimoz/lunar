import Foundation
import SwiftUI

/// Delimiter kind matched during LaTeX/Markdown parsing.
public enum MathDelimiterKind: String, Sendable, Equatable {
    case rawHeuristic
    case displayDollar
    case displayBracket
    case inlineParen
    case inlineDollar
    case environment
}

/// Extracted math expression ready for local KaTeX rendering.
public struct MathExpression: Sendable, Equatable {
    public let latex: String
    public let displayMode: Bool
    public let kind: MathDelimiterKind

    public init(latex: String, displayMode: Bool, kind: MathDelimiterKind) {
        self.latex = latex
        self.displayMode = displayMode
        self.kind = kind
    }
}

/// Structured result of parsing Markdown + LaTeX input.
public struct ParsedMathDocument: Sendable, Equatable {
    public let rawText: String
    public let isRawLatexCandidate: Bool
    public let rawLatexDisplayMode: Bool
    public let htmlFragment: String
    public let mathExpressions: [MathExpression]

    public init(
        rawText: String,
        isRawLatexCandidate: Bool,
        rawLatexDisplayMode: Bool,
        htmlFragment: String,
        mathExpressions: [MathExpression]
    ) {
        self.rawText = rawText
        self.isRawLatexCandidate = isRawLatexCandidate
        self.rawLatexDisplayMode = rawLatexDisplayMode
        self.htmlFragment = htmlFragment
        self.mathExpressions = mathExpressions
    }
}

/// Pure-Swift Markdown and LaTeX delimiter parser mirroring `MathRenderer.tsx`
/// with strict HTML escaping and Unslop neutral styling.
public enum MathParser {
    private static let rawLatexTokens = [
        "\\frac", "\\lim", "\\int", "\\sum", "\\sqrt", "\\begin"
    ]

    private static let bareEnvironments = [
        "pmatrix", "bmatrix", "vmatrix", "Vmatrix", "matrix",
        "cases", "aligned", "align", "gather", "gathered",
        "split", "equation"
    ]

    /// Escapes HTML special characters in non-math text to prevent XSS injection.
    public static func escapeHTML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }

    /// Determines whether unwrapped text should attempt direct KaTeX rendering first.
    public static func shouldAttemptRawLatex(_ rawText: String) -> (candidate: Bool, displayMode: Bool) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$"),
              !trimmed.contains("\\["),
              !trimmed.contains("data:image/") else {
            return (false, false)
        }

        let looksLikeLatex = trimmed.hasPrefix("\\")
            || rawLatexTokens.contains { trimmed.contains($0) }

        guard looksLikeLatex else { return (false, false) }

        let displayMode = trimmed.contains("\n")
            || trimmed.contains("\\\\")
            || trimmed.count > 25
            || trimmed.hasPrefix("\\begin")
        return (true, displayMode)
    }

    /// Parses raw Markdown + LaTeX text into an HTML fragment and ordered math expressions.
    public static func parse(_ rawText: String) -> ParsedMathDocument {
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedMathDocument(
                rawText: rawText,
                isRawLatexCandidate: false,
                rawLatexDisplayMode: false,
                htmlFragment: "",
                mathExpressions: []
            )
        }

        let (isRawCandidate, rawDisplayMode) = shouldAttemptRawLatex(normalized)

        enum SlotPayload {
            case codeBlock(html: String)
            case image(html: String)
            case math(index: Int, displayMode: Bool)
        }

        var slots: [(token: String, payload: SlotPayload)] = []
        var mathExpressions: [MathExpression] = []

        func makeToken(_ index: Int) -> String {
            "@@LUNARSLOT\(index)@@"
        }

        var working = normalized

        // 1. Fenced code blocks ```lang\n...\n```
        working = replacingMatches(
            in: working,
            pattern: #"```([a-zA-Z0-9_-]*)\n([\s\S]*?)```"#,
            options: []
        ) { match, ns in
            let codeRange = match.range(at: 2)
            let code = codeRange.location != NSNotFound ? ns.substring(with: codeRange) : ""
            let escaped = escapeHTML(code.trimmingCharacters(in: .newlines))
            let token = makeToken(slots.count)
            let html = "<pre class=\"lunar-code-block\"><code>\(escaped)</code></pre>"
            slots.append((token, .codeBlock(html: html)))
            return token
        }

        // 1b. Safe inline base64 data-URI images ![alt](data:image/(png|jpeg|webp);base64,...)
        working = replacingMatches(
            in: working,
            pattern: #"!\[([^\]]*)\]\((data:image/(?:png|jpeg|webp);base64,[A-Za-z0-9+/=]+)\)"#,
            options: []
        ) { match, ns in
            let altRange = match.range(at: 1)
            let srcRange = match.range(at: 2)
            let altText = altRange.location != NSNotFound ? ns.substring(with: altRange) : ""
            let srcText = srcRange.location != NSNotFound ? ns.substring(with: srcRange) : ""
            let escapedAlt = escapeHTML(altText)
            let token = makeToken(slots.count)
            let html = "<div class=\"lunar-image-wrap\"><img class=\"lunar-markdown-image\" src=\"\(srcText)\" alt=\"\(escapedAlt)\" /></div>"
            slots.append((token, .image(html: html)))
            return token
        }

        // 2. Display math: $$ ... $$
        working = replacingMatches(
            in: working,
            pattern: #"(?<!\\)\$\$([\s\S]*?)(?<!\\)\$\$"#,
            options: []
        ) { match, ns in
            let mathRange = match.range(at: 1)
            let latex = ns.substring(with: mathRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let mathIdx = mathExpressions.count
            mathExpressions.append(MathExpression(latex: latex, displayMode: true, kind: .displayDollar))
            let token = makeToken(slots.count)
            slots.append((token, .math(index: mathIdx, displayMode: true)))
            return token
        }

        // 3. Display math: \[ ... \]
        working = replacingMatches(
            in: working,
            pattern: #"\\\[([\s\S]*?)\\\]"#,
            options: []
        ) { match, ns in
            let mathRange = match.range(at: 1)
            let latex = ns.substring(with: mathRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let mathIdx = mathExpressions.count
            mathExpressions.append(MathExpression(latex: latex, displayMode: true, kind: .displayBracket))
            let token = makeToken(slots.count)
            slots.append((token, .math(index: mathIdx, displayMode: true)))
            return token
        }

        // 4. Inline math: \( ... \)
        working = replacingMatches(
            in: working,
            pattern: #"\\\(([\s\S]*?)\\\)"#,
            options: []
        ) { match, ns in
            let mathRange = match.range(at: 1)
            let latex = ns.substring(with: mathRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let mathIdx = mathExpressions.count
            mathExpressions.append(MathExpression(latex: latex, displayMode: false, kind: .inlineParen))
            let token = makeToken(slots.count)
            slots.append((token, .math(index: mathIdx, displayMode: false)))
            return token
        }

        // 5. Inline math: $ ... $
        working = replacingMatches(
            in: working,
            pattern: #"(?<!\\)\$(?!\$)((?:\\\$|[^\$])+?)(?<!\\)\$"#,
            options: []
        ) { match, ns in
            let mathRange = match.range(at: 1)
            let latex = ns.substring(with: mathRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let mathIdx = mathExpressions.count
            mathExpressions.append(MathExpression(latex: latex, displayMode: false, kind: .inlineDollar))
            let token = makeToken(slots.count)
            slots.append((token, .math(index: mathIdx, displayMode: false)))
            return token
        }

        // 6. Bare LaTeX environments: \begin{...}...\end{...}
        let envUnion = bareEnvironments.joined(separator: "|")
        working = replacingMatches(
            in: working,
            pattern: #"\\begin\{("# + envUnion + #")\}([\s\S]*?)\\end\{\1\}"#,
            options: []
        ) { match, ns in
            let fullMatch = ns.substring(with: match.range(at: 0)).trimmingCharacters(in: .whitespacesAndNewlines)
            let mathIdx = mathExpressions.count
            mathExpressions.append(MathExpression(latex: fullMatch, displayMode: true, kind: .environment))
            let token = makeToken(slots.count)
            slots.append((token, .math(index: mathIdx, displayMode: true)))
            return token
        }

        // Step 2: Parse Markdown lines with HTML escaping on all non-math text
        let lines = working.components(separatedBy: "\n")
        var parsedLines: [String] = []
        var inList = false

        func closeListIfNeeded() {
            if inList {
                parsedLines.append("</ul>")
                inList = false
            }
        }

        let blockSlotTokens = Set(slots.compactMap { entry -> String? in
            switch entry.payload {
            case .codeBlock, .image:
                return entry.token
            case .math(_, let displayMode):
                return displayMode ? entry.token : nil
            }
        })

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("### ") {
                closeListIfNeeded()
                parsedLines.append("<h4>\(formatInlineMarkdown(String(line.dropFirst(4))))</h4>")
                continue
            }
            if line.hasPrefix("## ") {
                closeListIfNeeded()
                parsedLines.append("<h3>\(formatInlineMarkdown(String(line.dropFirst(3))))</h3>")
                continue
            }
            if line.hasPrefix("# ") {
                closeListIfNeeded()
                parsedLines.append("<h2>\(formatInlineMarkdown(String(line.dropFirst(2))))</h2>")
                continue
            }

            if trimmedLine == "---" || trimmedLine == "***" {
                closeListIfNeeded()
                parsedLines.append("<hr />")
                continue
            }

            if line.hasPrefix("> ") {
                closeListIfNeeded()
                parsedLines.append("<blockquote>\(formatInlineMarkdown(String(line.dropFirst(2))))</blockquote>")
                continue
            }

            if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") {
                if !inList {
                    parsedLines.append("<ul>")
                    inList = true
                }
                let content = String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                parsedLines.append("<li>\(formatInlineMarkdown(content))</li>")
                continue
            }

            if let numMatch = firstRegexMatch(in: trimmedLine, pattern: #"^(\d+)\.\s+(.*)$"#) {
                closeListIfNeeded()
                let ns = trimmedLine as NSString
                let num = escapeHTML(ns.substring(with: numMatch.range(at: 1)))
                let body = formatInlineMarkdown(ns.substring(with: numMatch.range(at: 2)))
                parsedLines.append("<div class=\"lunar-ordered-item\"><span class=\"lunar-ordered-num\">\(num).</span><div>\(body)</div></div>")
                continue
            }

            closeListIfNeeded()

            if trimmedLine.isEmpty {
                parsedLines.append("<div class=\"lunar-spacer\"></div>")
            } else if blockSlotTokens.contains(where: { line.contains($0) }) {
                parsedLines.append("<div class=\"lunar-block-line\">\(formatInlineMarkdown(line))</div>")
            } else {
                parsedLines.append("<p>\(formatInlineMarkdown(line))</p>")
            }
        }

        closeListIfNeeded()

        var finalHTML = parsedLines.joined(separator: "\n")
        for (token, payload) in slots {
            let replacement: String
            switch payload {
            case .codeBlock(let html), .image(let html):
                replacement = html
            case .math(let index, let displayMode):
                if displayMode {
                    replacement = "<div class=\"lunar-math-display\" data-math-index=\"\(index)\" data-display=\"true\"></div>"
                } else {
                    replacement = "<span class=\"lunar-math-inline\" data-math-index=\"\(index)\" data-display=\"false\"></span>"
                }
            }
            finalHTML = finalHTML.replacingOccurrences(of: token, with: replacement)
        }

        return ParsedMathDocument(
            rawText: rawText,
            isRawLatexCandidate: isRawCandidate,
            rawLatexDisplayMode: rawDisplayMode,
            htmlFragment: finalHTML,
            mathExpressions: mathExpressions
        )
    }

    /// Formats inline Markdown (`**bold**`, `*italic*`, `` `code` ``) after HTML-escaping text.
    public static func formatInlineMarkdown(_ raw: String) -> String {
        var out = escapeHTML(raw)

        // Inline code first so asterisks inside `...` are preserved literally.
        var codeTokens: [(String, String)] = []
        out = replacingMatches(in: out, pattern: #"`([^`]+)`"#, options: []) { match, ns in
            let inner = ns.substring(with: match.range(at: 1))
            let token = "@@LUNARCODE\(codeTokens.count)@@"
            codeTokens.append((token, "<code class=\"lunar-inline-code\">\(inner)</code>"))
            return token
        }

        // Bold: **...**
        out = replacingMatches(in: out, pattern: #"\*\*(.+?)\*\*"#, options: []) { match, ns in
            let inner = ns.substring(with: match.range(at: 1))
            return "<strong>\(inner)</strong>"
        }

        // Italic: *...*
        out = replacingMatches(in: out, pattern: #"\*([^\*]+?)\*"#, options: []) { match, ns in
            let inner = ns.substring(with: match.range(at: 1))
            return "<em>\(inner)</em>"
        }

        for (token, html) in codeTokens {
            out = out.replacingOccurrences(of: token, with: html)
        }
        return out
    }

    /// Builds the JSON payload passed to `window.lunarUpdate(payload)` for flicker-free incremental updates.
    public static func buildUpdatePayloadJSON(
        parsed: ParsedMathDocument,
        colorScheme: ColorScheme,
        fontFamily: String = "serif",
        fontSize: String = "base",
        compact: Bool = false
    ) -> String {
        let isDark = (colorScheme == .dark)

        let textPrimary = isDark ? "rgba(255, 255, 255, 0.92)" : "rgba(15, 23, 42, 0.92)"
        let textSecondary = isDark ? "rgba(255, 255, 255, 0.64)" : "rgba(15, 23, 42, 0.64)"
        let surface = isDark ? "rgba(255, 255, 255, 0.05)" : "rgba(15, 23, 42, 0.04)"
        let border = isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(15, 23, 42, 0.08)"
        let accent = isDark ? "rgba(244, 244, 245, 0.45)" : "rgba(24, 24, 27, 0.40)"

        let basePx: Int = switch fontSize {
        case "sm": compact ? 12 : 13
        case "lg": compact ? 14 : 16
        case "xl": compact ? 15 : 18
        default: compact ? 13 : 14
        }

        let bodyFontStack: String = switch fontFamily {
        case "mono": "ui-monospace, 'SF Mono', Menlo, monospace"
        case "sans": "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        default: "'New York', 'STIX Two Text', Georgia, serif"
        }

        let expressions: [[String: Any]] = parsed.mathExpressions.map {
            ["latex": $0.latex, "displayMode": $0.displayMode]
        }
        let rawConfig: [String: Any] = [
            "candidate": parsed.isRawLatexCandidate,
            "rawText": parsed.rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            "displayMode": parsed.rawLatexDisplayMode
        ]
        let theme: [String: Any] = [
            "textPrimary": textPrimary,
            "textSecondary": textSecondary,
            "surface": surface,
            "border": border,
            "accent": accent,
            "fontStack": bodyFontStack,
            "fontSizePx": basePx,
            "compact": compact
        ]

        let payload: [String: Any] = [
            "htmlFragment": parsed.htmlFragment,
            "rawConfig": rawConfig,
            "expressions": expressions,
            "theme": theme
        ]
        return encodeJSONString(payload) ?? "{}"
    }

    /// Builds a self-contained offline HTML document rendered by local KaTeX inside `WKWebView`.
    public static func buildDocumentHTML(
        parsed: ParsedMathDocument,
        colorScheme: ColorScheme,
        fontFamily: String = "serif",
        fontSize: String = "base",
        compact: Bool = false,
        katexCSS: String,
        katexJS: String
    ) -> String {
        let isDark = (colorScheme == .dark)

        let textPrimary = isDark ? "rgba(255, 255, 255, 0.92)" : "rgba(15, 23, 42, 0.92)"
        let textSecondary = isDark ? "rgba(255, 255, 255, 0.64)" : "rgba(15, 23, 42, 0.64)"
        let surface = isDark ? "rgba(255, 255, 255, 0.05)" : "rgba(15, 23, 42, 0.04)"
        let border = isDark ? "rgba(255, 255, 255, 0.08)" : "rgba(15, 23, 42, 0.08)"
        let accent = isDark ? "rgba(244, 244, 245, 0.45)" : "rgba(24, 24, 27, 0.40)"

        let basePx: Int = switch fontSize {
        case "sm": compact ? 12 : 13
        case "lg": compact ? 14 : 16
        case "xl": compact ? 15 : 18
        default: compact ? 13 : 14
        }

        let bodyFontStack: String = switch fontFamily {
        case "mono": "ui-monospace, 'SF Mono', Menlo, monospace"
        case "sans": "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif"
        default: "'New York', 'STIX Two Text', Georgia, serif"
        }

        let initialPayloadJSON = buildUpdatePayloadJSON(
            parsed: parsed,
            colorScheme: colorScheme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            compact: compact
        )
        let bodyClass = compact ? " class=\"lunar-compact\"" : ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <style>
        \(katexCSS)
        </style>
        <style>
        :root {
          --lunar-text-primary: \(textPrimary);
          --lunar-text-secondary: \(textSecondary);
          --lunar-surface: \(surface);
          --lunar-border: \(border);
          --lunar-accent: \(accent);
        }
        * { box-sizing: border-box; }
        *::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          color: var(--lunar-text-primary);
          font-family: \(bodyFontStack);
          font-size: \(basePx)px;
          line-height: 1.55;
          -webkit-font-smoothing: antialiased;
          overflow: hidden !important;
        }
        #lunar-root {
          display: flow-root;
          width: 100%;
          word-wrap: break-word;
          overflow-wrap: anywhere;
          overflow-x: hidden;
        }
        h2, h3, h4 {
          font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
          font-weight: 600;
          color: var(--lunar-text-primary);
          margin: 10px 0 4px;
        }
        h2 { font-size: 1.2em; }
        h3 { font-size: 1.08em; }
        h4 { font-size: 0.96em; color: var(--lunar-text-secondary); }
        strong { font-weight: 600; color: var(--lunar-text-primary); }
        hr { border: none; border-top: 1px solid var(--lunar-border); margin: 12px 0; }
        blockquote {
          margin: 8px 0;
          padding: 6px 12px;
          border-left: 2px solid var(--lunar-accent);
          background: var(--lunar-surface);
          color: var(--lunar-text-secondary);
          font-style: normal;
          border-radius: 0 6px 6px 0;
        }
        ul {
          margin: 6px 0;
          padding-left: 18px;
          color: var(--lunar-text-secondary);
        }
        li { margin: 2px 0; }
        .lunar-ordered-item {
          display: flex;
          align-items: flex-start;
          gap: 8px;
          margin: 4px 0;
          color: var(--lunar-text-secondary);
        }
        .lunar-ordered-num {
          font-family: ui-monospace, 'SF Mono', Menlo, monospace;
          font-variant-numeric: tabular-nums;
          font-size: 0.85em;
          color: var(--lunar-text-secondary);
          margin-top: 2px;
        }
        .lunar-code-block {
          margin: 8px 0;
          padding: 10px 12px;
          border-radius: 8px;
          background: var(--lunar-surface);
          border: 1px solid var(--lunar-border);
          font-family: ui-monospace, 'SF Mono', Menlo, monospace;
          font-size: 0.86em;
          overflow-x: auto;
        }
        .lunar-inline-code {
          font-family: ui-monospace, 'SF Mono', Menlo, monospace;
          font-size: 0.86em;
          padding: 1px 5px;
          border-radius: 4px;
          background: var(--lunar-surface);
          border: 1px solid var(--lunar-border);
        }
        .lunar-math-pending {
          display: inline-block;
          font-family: ui-monospace, 'SF Mono', Menlo, monospace;
          font-size: 0.88em;
          color: var(--lunar-text-secondary);
          background: var(--lunar-surface);
          padding: 1px 6px;
          border-radius: 4px;
        }
        .katex { font-size: 1.06em; }
        .katex-display { margin: 4px 0; overflow-x: auto; overflow-y: hidden; }
        p { margin: 4px 0; }
        .lunar-math-display { margin: 8px 0; text-align: center; overflow-x: auto; }
        .lunar-image-wrap { margin: 8px 0; }
        .lunar-markdown-image {
          display: block;
          max-width: 100%;
          max-height: 300px;
          width: auto;
          height: auto;
          border-radius: 8px;
          border: 1px solid var(--lunar-border);
        }
        .lunar-spacer { height: 8px; }
        body.lunar-compact p, body.lunar-compact .lunar-block-line { margin: 0; }
        body.lunar-compact .lunar-math-display { margin: 2px 0; text-align: left; }
        body.lunar-compact .lunar-spacer { height: 4px; }
        </style>
        </head>
        <body\(bodyClass)>
        <div id="lunar-root">\(parsed.htmlFragment)</div>
        <script>
        \(katexJS)
        </script>
        <script>
        (function() {
          const root = document.getElementById('lunar-root');
          let lastReportedHeight = 0;

          function reportHeight() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.lunarHeight) {
              const h = Math.ceil(Math.max(root.getBoundingClientRect().height, root.scrollHeight));
              if (Math.abs(h - lastReportedHeight) < 2) return;
              lastReportedHeight = h;
              window.webkit.messageHandlers.lunarHeight.postMessage(h);
            }
          }

          function applyTheme(theme) {
            if (!theme || typeof theme !== 'object') return;
            const style = document.documentElement.style;
            if (typeof theme.textPrimary === 'string') style.setProperty('--lunar-text-primary', theme.textPrimary);
            if (typeof theme.textSecondary === 'string') style.setProperty('--lunar-text-secondary', theme.textSecondary);
            if (typeof theme.surface === 'string') style.setProperty('--lunar-surface', theme.surface);
            if (typeof theme.border === 'string') style.setProperty('--lunar-border', theme.border);
            if (typeof theme.accent === 'string') style.setProperty('--lunar-accent', theme.accent);
            if (typeof theme.fontStack === 'string') document.body.style.fontFamily = theme.fontStack;
            if (typeof theme.fontSizePx === 'number') document.body.style.fontSize = theme.fontSizePx + 'px';
            document.body.classList.toggle('lunar-compact', Boolean(theme.compact));
          }

          function renderFallbackSlots(expressions) {
            const list = Array.isArray(expressions) ? expressions : [];
            const slots = root.querySelectorAll('[data-math-index]');
            for (const el of slots) {
              const idx = Number(el.getAttribute('data-math-index'));
              const item = list[idx];
              if (!item || typeof item.latex !== 'string') continue;
              if (typeof katex === 'undefined') {
                el.className = 'lunar-math-pending';
                el.textContent = item.latex;
                continue;
              }
              try {
                katex.render(item.latex, el, {
                  displayMode: Boolean(item.displayMode),
                  throwOnError: true
                });
              } catch (_) {
                el.className = 'lunar-math-pending';
                el.textContent = item.latex;
              }
            }
          }

          window.lunarUpdate = function(payload) {
            if (!payload || typeof payload !== 'object') return;
            applyTheme(payload.theme);
            root.innerHTML = (typeof payload.htmlFragment === 'string') ? payload.htmlFragment : '';

            const rawConfig = payload.rawConfig;
            const expressions = payload.expressions;

            if (typeof katex !== 'undefined' && rawConfig && rawConfig.candidate && typeof rawConfig.rawText === 'string' && rawConfig.rawText.length > 0) {
              try {
                const html = katex.renderToString(rawConfig.rawText, {
                  displayMode: Boolean(rawConfig.displayMode),
                  throwOnError: true
                });
                if (typeof html === 'string' && html.length > 0) {
                  root.innerHTML = '<div class="lunar-math-display">' + html + '</div>';
                } else {
                  renderFallbackSlots(expressions);
                }
              } catch (_) {
                if (Array.isArray(expressions) && expressions.length > 0) {
                  renderFallbackSlots(expressions);
                } else {
                  const fallback = document.createElement('div');
                  fallback.className = 'lunar-math-pending';
                  fallback.textContent = rawConfig.rawText;
                  root.innerHTML = '';
                  root.appendChild(fallback);
                }
              }
            } else {
              renderFallbackSlots(expressions);
            }

            reportHeight();
            root.querySelectorAll('img.lunar-markdown-image').forEach(function(img) {
              if (!img.complete) {
                img.addEventListener('load', reportHeight, { once: true });
              }
            });
            if (typeof requestAnimationFrame === 'function') {
              requestAnimationFrame(reportHeight);
            }
          };

          window.lunarUpdate(\(initialPayloadJSON));

          if (document.fonts && document.fonts.ready) {
            document.fonts.ready.then(reportHeight);
          }
          if (typeof ResizeObserver !== 'undefined') {
            new ResizeObserver(reportHeight).observe(root);
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Regex & JSON Helpers

    private static func replacingMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let replacement = transform(match, ns)
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private static func firstRegexMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    }

    private static func encodeJSONString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Prevent </script> breakout inside inline <script>
        return str.replacingOccurrences(of: "</", with: "<\\/")
    }
}
