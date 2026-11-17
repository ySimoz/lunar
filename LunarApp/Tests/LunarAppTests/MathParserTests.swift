import SwiftUI
import Testing
@testable import LunarApp

@Suite("MathParser, Offline KaTeX & Symbol Catalog")
struct MathParserTests {
    @Test("Offline KaTeX resources load from Bundle.module with flattened font URLs")
    func offlineKatexResourcesAvailable() {
        let resources = KatexResources.shared
        #expect(resources.isAvailable)
        #expect(resources.css.contains("KaTeX_Main-Regular.woff2"))
        #expect(!resources.css.contains("url(fonts/"))
        #expect(resources.js.contains("katex"))
        #expect(resources.baseURL != nil)
    }

    @Test("Extracts all supported LaTeX delimiters and fenced code blocks")
    func delimiterExtraction() {
        let input = """
        ```python
        x = 1 < 2
        ```

        Inline $a + b$ and paren \\(c^2\\).

        $$\\int_0^1 x\\,dx$$

        \\[\\sum_{n=1}^{\\infty} \\frac{1}{n^2}\\]

        \\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}
        """

        let parsed = MathParser.parse(input)
        #expect(!parsed.isRawLatexCandidate)
        #expect(parsed.mathExpressions.count == 5)

        #expect(parsed.mathExpressions[0] == MathExpression(latex: "\\int_0^1 x\\,dx", displayMode: true, kind: .displayDollar))
        #expect(parsed.mathExpressions[1] == MathExpression(latex: "\\sum_{n=1}^{\\infty} \\frac{1}{n^2}", displayMode: true, kind: .displayBracket))
        #expect(parsed.mathExpressions[2] == MathExpression(latex: "c^2", displayMode: false, kind: .inlineParen))
        #expect(parsed.mathExpressions[3] == MathExpression(latex: "a + b", displayMode: false, kind: .inlineDollar))
        #expect(parsed.mathExpressions[4].kind == .environment)
        #expect(parsed.mathExpressions[4].displayMode == true)
        #expect(parsed.mathExpressions[4].latex.contains("\\begin{pmatrix}"))

        #expect(parsed.htmlFragment.contains("<pre class=\"lunar-code-block\"><code>x = 1 &lt; 2</code></pre>"))
        #expect(parsed.htmlFragment.contains("data-math-index=\"0\""))
        #expect(parsed.htmlFragment.contains("data-math-index=\"4\""))
    }

    @Test("Raw unwrapped LaTeX heuristic matches unwrapped math and skips prose or dollar-wrapped math")
    func rawLatexHeuristic() {
        let rawFrac = MathParser.shouldAttemptRawLatex("\\frac{a}{b}")
        #expect(rawFrac.candidate == true)
        #expect(rawFrac.displayMode == false)

        let rawMatrix = MathParser.shouldAttemptRawLatex("\\begin{bmatrix} 1 & 2 \\\\ 3 & 4 \\end{bmatrix}")
        #expect(rawMatrix.candidate == true)
        #expect(rawMatrix.displayMode == true)

        let wrapped = MathParser.shouldAttemptRawLatex("$\\frac{a}{b}$")
        #expect(wrapped.candidate == false)

        let prose = MathParser.shouldAttemptRawLatex("A compact set in a metric space is closed and bounded.")
        #expect(prose.candidate == false)

        let bracketWrapped = MathParser.shouldAttemptRawLatex("\\[\\lim_{x\\to 0} x\\]")
        #expect(bracketWrapped.candidate == false)
    }

    @Test("Parses Markdown blocks and escapes HTML/XSS payloads safely")
    func markdownAndXSSSafety() {
        let input = """
        # Title <script>alert("xss")</script>
        ## Section & Details
        ### Subsection 'quoted'
        ---
        > Quote with **bold** and *italic* and `x < y`
        - First item <img src=x onerror=alert(1)>
        1. Ordered **step**
        """

        let parsed = MathParser.parse(input)
        let html = parsed.htmlFragment

        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;"))
        #expect(html.contains("&amp;"))
        #expect(html.contains("&#39;quoted&#39;"))
        #expect(html.contains("<h2>Title"))
        #expect(html.contains("<h3>Section"))
        #expect(html.contains("<h4>Subsection"))
        #expect(html.contains("<hr />"))
        #expect(html.contains("<blockquote>Quote with <strong>bold</strong> and <em>italic</em> and <code class=\"lunar-inline-code\">x &lt; y</code></blockquote>"))
        #expect(html.contains("<ul>"))
        #expect(html.contains("<li>First item &lt;img src=x onerror=alert(1)&gt;</li>"))
        #expect(html.contains("<div class=\"lunar-ordered-item\">"))

        // Verify built HTML document is offline, adaptive, and free of indigo/cyan/italic blockquotes or script breakouts
        let fullHTML = MathParser.buildDocumentHTML(
            parsed: MathParser.parse("$</script>$"),
            colorScheme: .dark,
            katexCSS: KatexResources.shared.css,
            katexJS: KatexResources.shared.js
        )
        #expect(!fullHTML.contains("cdn.jsdelivr"))
        #expect(!fullHTML.contains("unpkg.com"))
        #expect(!fullHTML.contains("indigo"))
        #expect(!fullHTML.contains("cyan"))
        #expect(!fullHTML.contains("#10B981"))
        #expect(!fullHTML.contains("#059669"))
        #expect(fullHTML.contains("window.lunarUpdate"))
        #expect(fullHTML.contains("lunar-math-pending"))
        #expect(fullHTML.contains("font-style: normal;"))
        #expect(fullHTML.contains("<\\/script>"))
    }

    @Test("Partial or invalid LaTeX never outputs 'undefined' in parsed HTML or update payloads")
    func partialAndInvalidLatexSafety() {
        let samples = [
            "",
            "$",
            "$$",
            "\\(",
            "$\\frac{a}{",
            "\\frac{1}{",
            "$$\\begin{pmatrix} 1 &",
            "$\\sqrt{x + $",
            "\\unknownCommand{123}"
        ]

        for sample in samples {
            let parsed = MathParser.parse(sample)
            #expect(!parsed.htmlFragment.lowercased().contains("undefined"))

            let payload = MathParser.buildUpdatePayloadJSON(
                parsed: parsed,
                colorScheme: .dark,
                fontFamily: "serif",
                fontSize: "base",
                compact: false
            )
            #expect(!payload.lowercased().contains("undefined"))

            let htmlShell = MathParser.buildDocumentHTML(
                parsed: parsed,
                colorScheme: .light,
                katexCSS: "",
                katexJS: ""
            )
            let rootMarker = "<div id=\"lunar-root\">"
            let rootStart = htmlShell.range(of: rootMarker)?.upperBound ?? htmlShell.startIndex
            let rootEnd = htmlShell.range(of: "</div>", range: rootStart..<htmlShell.endIndex)?.lowerBound ?? htmlShell.endIndex
            let rootHTML = String(htmlShell[rootStart..<rootEnd])
            #expect(!rootHTML.lowercased().contains("undefined"))
            #expect(!htmlShell.contains("#10B981"))
            #expect(!htmlShell.contains("#059669"))
        }
    }

    @Test("MathSymbolCatalog contains all 53 templates across 5 categories with search & insertion formatting")
    func symbolCatalogCountSearchAndFormatting() {
        #expect(MathSymbolCatalog.all.count == 53)
        #expect(MathSymbolCatalog.filter(category: .calculus, query: "").count == 9)
        #expect(MathSymbolCatalog.filter(category: .algebra, query: "").count == 14)
        #expect(MathSymbolCatalog.filter(category: .logicAndSets, query: "").count == 12)
        #expect(MathSymbolCatalog.filter(category: .greek, query: "").count == 9)
        #expect(MathSymbolCatalog.filter(category: .operators, query: "").count == 9)

        let matrixMatches = MathSymbolCatalog.filter(category: .all, query: "determinant")
        #expect(matrixMatches.count == 1)
        #expect(matrixMatches[0].insertionText.hasPrefix("$$\\begin{vmatrix}"))

        let limit = MathSymbolCatalog.filter(category: .calculus, query: "limit").first
        #expect(limit?.insertionText == "$\\lim_{x \\to c} f(x)$")
    }
}
