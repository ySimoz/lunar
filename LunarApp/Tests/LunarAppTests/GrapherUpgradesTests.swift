import Foundation
import Testing
@testable import LunarApp

@Suite("2D Grapher Upgrades: Parameters, Root/Intersection Snapping & Card Bridge")
@MainActor
struct GrapherUpgradesTests {
    @Test("Extracts free scalar parameters while excluding built-ins and evaluates parameterized curves")
    func freeParameterExtractionAndEvaluation() throws {
        let trigParams = MathExpressionEvaluator.extractFreeParameters(from: "y = a*sin(b*x)")
        #expect(trigParams == ["a", "b"])

        let linearParams = MathExpressionEvaluator.extractFreeParameters(from: "y = m*x + c")
        #expect(linearParams == ["m", "c"])

        // Built-ins (x, y, e, pi, functions like asin) must not be detected as free parameters
        let builtinOnly = MathExpressionEvaluator.extractFreeParameters(from: "y = asin(x / 2) + pi * e")
        #expect(builtinOnly.isEmpty)

        // Independent variables t, r, theta are excluded from scalar parameters
        #expect(MathExpressionEvaluator.extractFreeParameters(from: "y = t*x").isEmpty)
        #expect(MathExpressionEvaluator.extractFreeParameters(from: "x^2 + y^2 = r^2").isEmpty)
        #expect(MathExpressionEvaluator.extractFreeParameters(from: "y = cos(theta)").isEmpty)

        let ast = try MathExpressionEvaluator.compileEquation("y = a*sin(b*x)")
        let env: [Character: Double] = ["a": 2.5, "b": 3.0]
        let xTest = Double.pi / 6.0
        // F(x, y) = y - a*sin(b*x); at y = 2.5 * sin(pi/2) = 2.5, F == 0
        let residual = ast.evaluate(x: xTest, y: 2.5, parameters: env)
        #expect(abs(residual) < 1e-12)

        // MarchingSquares respects parameter environment
        let circleAST = try MathExpressionEvaluator.compileEquation("x^2 + y^2 = k^2")
        let segments = MarchingSquares.extractSegments(
            ast: circleAST,
            xRange: -5...5,
            yRange: -5...5,
            columns: 100,
            rows: 100,
            parameters: ["k": 3.0]
        )
        #expect(!segments.isEmpty)
        for seg in segments {
            #expect(abs(hypot(seg.x1, seg.y1) - 3.0) < 0.2)
        }
    }

    @Test("GrapherViewModel manages parameter lifecycle, bounds clamping, and resets")
    func grapherViewModelParameters() {
        let vm = GrapherViewModel()
        vm.addPlottedEquation("y = a*sin(b*x)")
        #expect(vm.parameters.map(\.name) == ["a", "b"])
        #expect(vm.parameters[0].value == 1.0)
        #expect(vm.parameters[0].min == -10.0)
        #expect(vm.parameters[0].max == 10.0)
        #expect(vm.parameters[0].step == 0.1)

        vm.setParameterValue(name: "a", value: 4.2)
        #expect(vm.parameterEnvironment["a"] == 4.2)

        // Editing expression preserves existing parameter `a` and prunes removed `b` while adding `c`
        vm.equations[0].expression = "y = a*x + c"
        #expect(vm.parameters.map(\.name) == ["a", "c"])
        #expect(vm.parameterEnvironment["a"] == 4.2)
        #expect(vm.parameterEnvironment["c"] == 1.0)

        // Updating bounds clamps value cleanly and rejects invalid bounds
        vm.updateParameterBounds(name: "a", min: -2.0, max: 3.0, step: 0.25)
        #expect(vm.parameterEnvironment["a"] == 3.0)
        #expect(vm.parameters[0].step == 0.25)

        vm.resetParameter(name: "a")
        #expect(vm.parameterEnvironment["a"] == 1.0)
        #expect(vm.parameters[0].min == -10.0)
        #expect(vm.parameters[0].max == 10.0)
    }

    @Test("Numerical root finder and two-curve intersection solver achieve high accuracy")
    func rootsAndCurveIntersections() {
        let eq1 = EquationEntry(expression: "y = x^2 - 4", isVisible: true, colorIndex: 0)
        let eq2 = EquationEntry(expression: "y = x - 2", isVisible: true, colorIndex: 1)

        let points = GraphFeatureSolver.findKeyPoints(
            equations: [(eq1.id, eq1.expression), (eq2.id, eq2.expression)],
            parameters: [:],
            xRange: -6...6,
            yRange: -6...6
        )

        let xIntercepts = points.filter { $0.kind == .xIntercept }
        #expect(xIntercepts.contains { abs($0.x + 2.0) < 1e-6 && abs($0.y) < 1e-6 })

        let yIntercepts = points.filter { $0.kind == .yIntercept }
        #expect(yIntercepts.contains { abs($0.x) < 1e-6 && abs($0.y + 4.0) < 1e-6 })
        #expect(yIntercepts.contains { abs($0.x) < 1e-6 && abs($0.y + 2.0) < 1e-6 })

        // Intersection of x^2 - 4 and x - 2 -> x^2 - x - 2 = 0 -> (-1, -3) and (2, 0)
        let intersections = points.filter { $0.kind == .intersection }
        #expect(intersections.count == 2)
        #expect(intersections.contains { abs($0.x + 1.0) < 1e-6 && abs($0.y + 3.0) < 1e-6 })
        #expect(intersections.contains { abs($0.x - 2.0) < 1e-6 && abs($0.y) < 1e-6 })

        // Pole rejection: 1/x has no real x-intercepts across [-4, 4]
        let poleRoots = GraphFeatureSolver.findRoots(of: { 1.0 / $0 }, in: -4...4, ySpan: 8.0)
        #expect(poleRoots.isEmpty)

        // Parameterized intersection + cursor snapping via GrapherViewModel
        let vm = GrapherViewModel()
        vm.centerX = 0
        vm.centerY = 0
        vm.halfWidth = 6
        vm.addPlottedEquation("y = x^2")
        vm.addPlottedEquation("y = a*x")
        vm.setParameterValue(name: "a", value: 3.0)

        let vmPoints = vm.visibleKeyPoints(aspect: 0.75)
        #expect(vmPoints.contains { $0.kind == .intersection && abs($0.x) < 1e-6 && abs($0.y) < 1e-6 })
        // (3, 9) is outside yRange [-4.5, 4.5], so zoom out to bring it inside
        vm.halfWidth = 14.0
        let zoomedPoints = vm.visibleKeyPoints(aspect: 0.75)
        let target = zoomedPoints.first { $0.kind == .intersection && abs($0.x - 3.0) < 1e-6 && abs($0.y - 9.0) < 1e-6 }
        #expect(target != nil)

        let snapped = vm.nearestKeyPoint(toWorldX: 3.05, worldY: 8.95, aspect: 0.75, from: zoomedPoints)
        #expect(snapped?.id == target?.id)
    }

    @Test("Graph snapshot renderer and card draft builder generate compact PNG data URI and valid Markdown")
    func graphSnapshotAndCardDraft() {
        let equations = [
            EquationEntry(expression: "y = a*sin(b*x)", isVisible: true, colorIndex: 0),
            EquationEntry(expression: "y = 0.5*x", isVisible: true, colorIndex: 1)
        ]
        let params = [
            GraphParameter(name: "a", value: 2.0),
            GraphParameter(name: "b", value: 1.0)
        ]
        let paramMap: [Character: Double] = ["a": 2.0, "b": 1.0]
        let xRange = -6.0...6.0
        let yRange = -4.0...4.0

        let keyPoints = GraphFeatureSolver.findKeyPoints(
            equations: equations.map { ($0.id, $0.expression) },
            parameters: paramMap,
            xRange: xRange,
            yRange: yRange
        )

        guard let draft = GraphCardDraftBuilder.build(
            equations: equations,
            parameters: params,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            isDark: false
        ) else {
            Issue.record("Expected GraphCardDraftBuilder to produce a non-nil draft")
            return
        }

        // Verify valid PNG signature and compact payload size (< 100 KB, far below 1 MiB CoreClient limit)
        #expect(draft.imageDataURI.hasPrefix("data:image/png;base64,"))
        #expect(draft.pngByteCount > 500)
        #expect(draft.pngByteCount < 100_000)
        #expect(draft.imageDataURI.utf8.count < 140_000)

        let base64Part = String(draft.imageDataURI.dropFirst("data:image/png;base64,".count))
        let decodedData = Data(base64Encoded: base64Part)
        #expect(decodedData != nil)
        #expect(decodedData?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        #expect(draft.front.contains("a = 2"))
        #expect(draft.back.contains("![2D Graph](data:image/png;base64,"))
        #expect(draft.explanation.contains("x-intercepts") || draft.explanation.contains("Intersections"))

        // Verify MathParser renders the data-URI image end-to-end and MathPlainText summarizes it cleanly
        let parsed = MathParser.parse(draft.back)
        #expect(parsed.htmlFragment.contains("<img class=\"lunar-markdown-image\" src=\"data:image/png;base64,"))
        #expect(parsed.htmlFragment.contains("alt=\"2D Graph\""))

        let plain = MathPlainText.format(draft.back)
        #expect(plain.contains("[2D Graph]"))
        #expect(!plain.contains("data:image/png;base64"))
    }
}
