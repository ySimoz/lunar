import Foundation
import Testing
@testable import LunarApp

@Suite("Symbolic CAS, Differentiation, Integration & Root Finding")
struct SymbolicCASTests {
    @Test("Symbolic differentiation handles power, product, quotient, and chain rules with simplification")
    func symbolicDifferentiationRules() throws {
        // Power + polynomial rule: d/dx(x^3 + 2x^2 - 5x + 7) = 3x^2 + 4x - 5
        let polyDeriv = try MathExpressionEvaluator.differentiate("x^3 + 2x^2 - 5x + 7", withRespectTo: "x")
        for x in [-2.0, -0.5, 0.0, 1.5, 3.0] {
            let expected = 3 * x * x + 4 * x - 5
            #expect(abs(polyDeriv.evaluate(x: x, y: 0) - expected) < 1e-9)
        }
        let polyLatex = polyDeriv.toLaTeX()
        #expect(polyLatex.contains("3x^{2}"))
        #expect(polyLatex.contains("4x"))

        // Product rule: d/dx(x * sin(x)) = sin(x) + x * cos(x)
        let prodDeriv = try MathExpressionEvaluator.differentiate("x * sin(x)", withRespectTo: "x")
        for x in [0.2, 1.0, 2.3] {
            let expected = sin(x) + x * cos(x)
            #expect(abs(prodDeriv.evaluate(x: x, y: 0) - expected) < 1e-9)
        }

        // Quotient rule: d/dx(sin(x) / x) = (x * cos(x) - sin(x)) / x^2
        let quotDeriv = try MathExpressionEvaluator.differentiate("sin(x) / x", withRespectTo: "x")
        for x in [0.5, 1.2, 2.5] {
            let expected = (x * cos(x) - sin(x)) / (x * x)
            #expect(abs(quotDeriv.evaluate(x: x, y: 0) - expected) < 1e-9)
        }
        #expect(quotDeriv.toLaTeX().contains("\\frac{"))

        // Chain rule: d/dx(sin(x^2) + ln(x^2 + 1) + exp(2x))
        let chainDeriv = try MathExpressionEvaluator.differentiate("sin(x^2) + ln(x^2 + 1) + exp(2x)", withRespectTo: "x")
        for x in [-0.7, 0.4, 1.1] {
            let expected = 2 * x * cos(x * x) + (2 * x) / (x * x + 1) + 2 * exp(2 * x)
            #expect(abs(chainDeriv.evaluate(x: x, y: 0) - expected) < 1e-9)
        }

        // Non-x variable differentiation: d/dt(t^4) = 4t^3
        let tDeriv = try MathExpressionEvaluator.differentiate("t^4", withRespectTo: "t")
        #expect(abs(tDeriv.evaluate(variables: ["t": 2.0]) - 32.0) < 1e-9)
        #expect(tDeriv.toLaTeX() == "4t^{3}")
    }

    @Test("Simpson numerical definite integration computes accurate integrals")
    func simpsonIntegration() throws {
        let cubicIntegral = try MathExpressionEvaluator.integrate("x^2", variable: "x", from: 0, to: 3)
        #expect(abs(cubicIntegral - 9.0) < 1e-9)

        let sinIntegral = try MathExpressionEvaluator.integrate("sin(x)", variable: "x", from: 0, to: Double.pi)
        #expect(abs(sinIntegral - 2.0) < 1e-7)

        let expIntegral = try MathExpressionEvaluator.integrate("exp(x)", variable: "x", from: 0, to: 1)
        #expect(abs(expIntegral - (M_E - 1.0)) < 1e-7)

        let reversed = try MathExpressionEvaluator.integrate("x", variable: "x", from: 2, to: 0)
        #expect(abs(reversed + 2.0) < 1e-9)
    }

    @Test("Numerical root finder solves equations including tangent roots")
    func numericalRootFinding() throws {
        let quadRoots = try MathExpressionEvaluator.solve("x^2 - 4 = 0", variable: "x")
        #expect(quadRoots.count == 2)
        #expect(abs(quadRoots[0] + 2.0) < 1e-6)
        #expect(abs(quadRoots[1] - 2.0) < 1e-6)

        let tangentRoots = try MathExpressionEvaluator.solve("(x - 3)^2", variable: "x", range: -10...10)
        #expect(tangentRoots.count == 1)
        #expect(abs(tangentRoots[0] - 3.0) < 1e-4)

        let trigRoots = try MathExpressionEvaluator.solve("cos(x) = 0", variable: "x", range: -4...4)
        #expect(trigRoots.count == 2)
        #expect(abs(trigRoots[0] + Double.pi / 2) < 1e-6)
        #expect(abs(trigRoots[1] - Double.pi / 2) < 1e-6)
    }

    @Test("CAS console command router handles equations, diff, integrate, solve, and arithmetic")
    func casCommandRouter() throws {
        let plotEq = try MathExpressionEvaluator.evaluateCAS("y = sin(x)")
        #expect(plotEq.shouldAutoPlot)
        #expect(plotEq.plottableExpression == "y = sin(x)")

        let implicitEq = try MathExpressionEvaluator.evaluateCAS("x^2 + y^2 = 9")
        #expect(implicitEq.shouldAutoPlot)
        #expect(implicitEq.plottableExpression == "x^2 + y^2 = 9")

        let diffCmd = try MathExpressionEvaluator.evaluateCAS("diff(x^3, x)")
        #expect(!diffCmd.shouldAutoPlot)
        #expect(diffCmd.outputLatex == "3x^{2}")
        #expect(diffCmd.plottableExpression == "y = 3 * x^2")

        let intCmd = try MathExpressionEvaluator.evaluateCAS("integrate(sin(x), x, 0, pi)")
        #expect(intCmd.outputLatex == "2")

        let solveCmd = try MathExpressionEvaluator.evaluateCAS("solve(x^2 = 9, x)")
        #expect(solveCmd.outputLatex.contains("-3"))
        #expect(solveCmd.outputLatex.contains("3"))

        let arith = try MathExpressionEvaluator.evaluateCAS("2 + 3 * 4")
        #expect(arith.outputLatex == "14")
    }
}
