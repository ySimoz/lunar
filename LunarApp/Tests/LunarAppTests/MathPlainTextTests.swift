import Foundation
import Testing
@testable import LunarApp

@Suite("MathPlainText Fast Unicode Formatter")
struct MathPlainTextTests {
    @Test("Formats fractions, roots, calculus symbols, Greek, logic, and blackboard bold")
    func formatsLatexExpressionsToUnicode() {
        #expect(MathPlainText.format("$\\frac{a}{b}$") == "(a)/(b)")
        #expect(MathPlainText.format("$$\\int_0^1 x^2\\,dx$$") == "∫₀¹ x² dx")
        #expect(MathPlainText.format("\\[\\sum_{n=1}^{\\infty} \\frac{1}{n^2}\\]") == "∑_(n=1)^(∞) (1)/(n²)")
        #expect(MathPlainText.format("\\(\\sqrt{x^2 + 1}\\)") == "√(x² + 1)")
        #expect(MathPlainText.format("\\forall x \\in \\mathbb{R}, \\exists y \\in \\mathbb{N}: x \\le y \\implies x \\neq y") == "∀ x ∈ ℝ, ∃ y ∈ ℕ: x ≤ y ⇒ x ≠ y")
        #expect(MathPlainText.format("\\alpha + \\beta \\approx \\pi \\cdot \\Omega") == "α + β ≈ π · Ω")
        #expect(MathPlainText.format("\\left|\\text{norm}(v)\\right| \\ge 0") == "|norm(v)| ≥ 0")
        #expect(MathPlainText.format("\\lim_{n \\to \\infty} a_n") == "lim_(n → ∞) aₙ")
    }

    @Test("Handles empty strings and plain prose without distortion")
    func handlesProseAndEmptyInput() {
        #expect(MathPlainText.format("   \n  ") == "")
        #expect(MathPlainText.format("State the Bolzano-Weierstrass Theorem.") == "State the Bolzano-Weierstrass Theorem.")
        #expect(MathPlainText.format("\\partial f / \\partial x \\nabla \\times F") == "∂ f / ∂ x ∇ × F")
    }
}
