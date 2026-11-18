import AppKit
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

        // Identically zero curve (e.g. a = 0 in y = a*sin(b*x)) must not flood the x-axis with spurious x-intercepts
        let flatVM = GrapherViewModel()
        flatVM.addPlottedEquation("y = a*sin(b*x)")
        flatVM.setParameterValue(name: "a", value: 0.0)
        let flatPoints = flatVM.visibleKeyPoints(aspect: 0.75)
        #expect(flatPoints.filter { $0.kind == .xIntercept }.isEmpty)
    }

    @Test("GraphSnapshotRenderer generates compact PNG data URI, equation label, and valid Markdown")
    func graphSnapshotAndLabel() {
        let equations = [
            EquationEntry(expression: "y = a*sin(b*x)", isVisible: true, colorIndex: 0),
            EquationEntry(expression: "y = 0.5*x", isVisible: true, colorIndex: 1)
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

        guard let snapshot = GraphSnapshotRenderer.renderPNG(
            equations: equations,
            parameters: paramMap,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            isDark: false
        ) else {
            Issue.record("Expected GraphSnapshotRenderer to produce a non-nil PNG snapshot")
            return
        }

        // Verify valid PNG signature and compact payload size (< 100 KB, far below 1 MiB CoreClient limit)
        #expect(snapshot.dataURI.hasPrefix("data:image/png;base64,"))
        #expect(snapshot.pngData.count > 500)
        #expect(snapshot.pngData.count < 100_000)
        #expect(snapshot.dataURI.utf8.count < 140_000)
        #expect(snapshot.pngData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        let expectedLabel = GraphSnapshotRenderer.defaultLabel(for: equations)
        #expect(expectedLabel.hasPrefix("Graph:"))

        let markdown = "![\(expectedLabel)](\(snapshot.dataURI))"
        let parsed = MathParser.parse(markdown)
        #expect(parsed.htmlFragment.contains("<img class=\"lunar-markdown-image\" src=\"data:image/png;base64,"))
        #expect(parsed.htmlFragment.contains("alt=\"\(expectedLabel)\""))

        let plain = MathPlainText.format(markdown)
        #expect(plain.contains("[\(expectedLabel)]"))
        #expect(!plain.contains("data:image/png;base64"))
    }

    @Test("CardAttachmentCodec extracts base64 images cleanly from text/LaTeX and supports removal & recompose")
    func attachmentCodecExtractComposeAndRemove() {
        let sampleURI1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let sampleURI2 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAQAAABFaP0WAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let raw = "Intercepts at $(0, 0)$\n\n![2D Graph](\(sampleURI1))\n\nExtra note below.\n\n![Second Plot](\(sampleURI2))"

        var (cleanText, attachments) = CardAttachmentCodec.extract(from: raw)
        #expect(!cleanText.contains("data:image/"))
        #expect(cleanText.contains("Intercepts at $(0, 0)$"))
        #expect(cleanText.contains("Extra note below."))
        #expect(attachments.count == 2)
        #expect(attachments[0].label == "2D Graph")
        #expect(attachments[1].label == "Second Plot")

        // Removing the first image leaves clean text + second image intact
        attachments.removeFirst()
        let recomposed = CardAttachmentCodec.compose(text: cleanText, attachments: attachments)
        #expect(recomposed.contains("Intercepts at $(0, 0)$"))
        #expect(recomposed.contains("Extra note below."))
        #expect(!recomposed.contains(sampleURI1))
        #expect(recomposed.contains("![Second Plot](\(sampleURI2))"))
    }

    @Test("CardAttachmentCodec encodes clipboard NSImage into compact data URI and decodes thumbnail")
    func attachmentCodecEncodesImage() {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 120,
            pixelsHigh: 80,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.addRepresentation(rep)

        let attachment = CardAttachmentCodec.encodeImage(image, label: "Snapshot")
        #expect(attachment != nil)
        #expect(attachment?.label == "Snapshot")
        #expect(attachment?.dataURI.hasPrefix("data:image/png;base64,") == true)
        #expect((attachment?.byteCount ?? 0) > 0)
        #expect(attachment.flatMap { CardAttachmentCodec.thumbnailImage(for: $0) } != nil)
    }

    @Test("GrapherViewModel caches key points across reads and refreshes when parameter changes")
    @MainActor
    func grapherViewModelKeyPointCache() {
        let vm = GrapherViewModel()
        vm.addPlottedEquation("x - a")

        let first = vm.visibleKeyPoints(aspect: 0.7)
        let second = vm.visibleKeyPoints(aspect: 0.7)
        #expect(first == second)
        #expect(first.contains { $0.kind == .xIntercept && abs($0.x - 1.0) < 1e-4 })

        vm.setParameterValue(name: "a", value: 3.5)
        let third = vm.visibleKeyPoints(aspect: 0.7)
        #expect(third != first)
        #expect(third.contains { $0.kind == .xIntercept && abs($0.x - 3.5) < 1e-4 })
    }

    @Test("CardAttachmentCodec preserves interleaved order between multiple images, text, and LaTeX")
    func attachmentCodecInterleavedAttributedRoundTrip() {
        let img1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let img2 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAQAAABFaP0WAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let interleaved = "Before image 1:\n\n![First](\(img1))\n\nMiddle math $x^2 + 1$\n\n![Second](\(img2))\n\nConclusion."

        let attr = CardAttachmentCodec.attributedString(from: interleaved)
        let roundTripped = CardAttachmentCodec.markdown(from: attr)
        #expect(roundTripped == interleaved)

        // Ensure raw-latex wrapper does not swallow Markdown containing interleaved images
        #expect(MathParser.shouldAttemptRawLatex("\\frac{1}{2}\n\n![First](\(img1))").candidate == false)

        // Removing the first image preserves text around it and keeps the second image intact
        let afterRemove = CardAttachmentCodec.removingAttachment(at: 0, from: interleaved)
        #expect(!afterRemove.contains(img1))
        #expect(afterRemove.contains("Before image 1:"))
        #expect(afterRemove.contains("Middle math $x^2 + 1$"))
        #expect(afterRemove.contains("![Second](\(img2))"))
        #expect(afterRemove.contains("Conclusion."))
    }

    @Test("CardAttachmentCodec assigns sequential Image N labels and unique graph labels")
    func attachmentCodecSequentialLabels() {
        let img1 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        #expect(CardAttachmentCodec.nextImageLabel(preferredLabel: nil, in: "") == "Image 1")
        let withFirst = "![Image 1](\(img1))"
        #expect(CardAttachmentCodec.nextImageLabel(preferredLabel: nil, in: withFirst) == "Image 2")

        let graphLabel = "Graph: sin(x)"
        #expect(CardAttachmentCodec.nextImageLabel(preferredLabel: graphLabel, in: "") == "Graph: sin(x)")
        let withGraph = "![Graph: sin(x)](\(img1))"
        #expect(CardAttachmentCodec.nextImageLabel(preferredLabel: graphLabel, in: withGraph) == "Graph: sin(x) (2)")
    }

    @Test("GraphSnapshotRenderer crops world bounds accurately and exports JPEG")
    func graphSnapshotCropAndJPEGExport() {
        let canvas = CGSize(width: 800, height: 400)
        // Right half horizontally [0, 10], top half vertically [0, 5] for x in [-10, 10], y in [-5, 5]
        let cropRect = CGRect(x: 400, y: 0, width: 400, height: 200)
        let target = GraphSnapshotRenderer.resolveExportViewport(
            cropRect: cropRect,
            canvasSize: canvas,
            xRange: -10.0...10.0,
            yRange: -5.0...5.0,
            longestEdge: 800
        )

        #expect(target.isCropped)
        #expect(abs(target.xRange.lowerBound - 0.0) < 1e-6)
        #expect(abs(target.xRange.upperBound - 10.0) < 1e-6)
        #expect(abs(target.yRange.lowerBound - 0.0) < 1e-6)
        #expect(abs(target.yRange.upperBound - 5.0) < 1e-6)
        #expect(target.width == 800)
        #expect(target.height == 400)

        let equations = [EquationEntry(expression: "x^2")]
        let jpegData = GraphSnapshotRenderer.renderImageData(
            equations: equations,
            parameters: [:],
            xRange: target.xRange,
            yRange: target.yRange,
            keyPoints: [],
            format: .jpeg,
            width: target.width,
            height: target.height
        )
        #expect(jpegData != nil)
        #expect(jpegData?.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test("Equation domain and range restrictions compile, clip contours, and filter key points")
    func equationRestrictionsAndSolverFiltering() throws {
        // Semicircle x^2 + y^2 = 4 {y >= 0}
        let semi = try MathExpressionEvaluator.compileGraphEquation("x^2 + y^2 = 4 {y >= 0}")
        #expect(semi.restrictions.count == 1)
        #expect(semi.satisfiesRestrictions(x: 0, y: 2, parameters: [:]) == true)
        #expect(semi.satisfiesRestrictions(x: 0, y: -2, parameters: [:]) == false)

        let semiSegments = MarchingSquares.extractSegments(
            ast: semi.implicitAST,
            xRange: -4...4,
            yRange: -4...4,
            parameters: [:],
            restrictions: semi.restrictions
        )
        #expect(!semiSegments.isEmpty)
        #expect(semiSegments.allSatisfy { $0.y1 >= -1e-4 && $0.y2 >= -1e-4 })

        // Chained interval + parameter inside restriction: y = x - 1 {-1 <= x <= a, y < 2}
        let chained = try MathExpressionEvaluator.compileGraphEquation("y = x^2 - 1 {0 <= x <= a}")
        #expect(chained.freeParameters == ["a"])
        #expect(chained.satisfiesRestrictions(x: 0.5, y: 0, parameters: ["a": 2]) == true)
        #expect(chained.satisfiesRestrictions(x: -0.5, y: 0, parameters: ["a": 2]) == false)

        // Root finding skips x = -1 root of x^2 - 1 because of {x >= 0}
        let eqID = UUID()
        let keyPoints = GraphFeatureSolver.findKeyPoints(
            equations: [(id: eqID, expression: "y = x^2 - 1 {x >= 0}")],
            parameters: [:],
            xRange: -4...4,
            yRange: -4...4
        )
        let xInts = keyPoints.filter { $0.kind == .xIntercept }
        #expect(xInts.count == 1)
        #expect(abs((xInts.first?.x ?? 0) - 1.0) < 1e-4)

        // Invalid syntax raises MathParseError.invalidRestriction
        #expect(throws: MathParseError.self) {
            _ = try MathExpressionEvaluator.compileGraphEquation("y = x^2 {x > 0")
        }
    }

    @Test("Parameter bounds update snaps values cleanly to natural and step-2 increments")
    @MainActor
    func parameterPresetSnapping() {
        let vm = GrapherViewModel()
        vm.addPlottedEquation("a*x")
        vm.setParameterValue(name: "a", value: 1.4)

        // Snap to step 1 integers/naturals
        vm.updateParameterBounds(name: "a", min: 0, max: 20, step: 1)
        #expect(vm.parameters[0].min == 0)
        #expect(vm.parameters[0].max == 20)
        #expect(vm.parameters[0].step == 1)
        #expect(vm.parameters[0].value == 1.0)

        // Snap to step 2 (0, 2, 4...)
        vm.setParameterValue(name: "a", value: 3.3)
        vm.updateParameterBounds(name: "a", min: 0, max: 20, step: 2)
        #expect(vm.parameters[0].step == 2)
        #expect(vm.parameters[0].value == 4.0)
    }

    @Test("Top-level symbolic and word inequalities compile, shade regions, and distinguish strict boundaries")
    func topLevelInequalitiesAndWordAliases() throws {
        // Strict half-plane using phrase alias
        let strictLine = try MathExpressionEvaluator.compileGraphEquation("y less than x + 2")
        #expect(strictLine.isInequality)
        #expect(strictLine.hasStrictBoundary)
        #expect(strictLine.isShaded(x: 0, y: 1, parameters: [:]) == true)
        #expect(strictLine.isShaded(x: 0, y: 3, parameters: [:]) == false)

        // Inclusive disk using `leq` keyword
        let disk = try MathExpressionEvaluator.compileGraphEquation("x^2 + y^2 leq 9")
        #expect(disk.isInequality)
        #expect(!disk.hasStrictBoundary)
        #expect(disk.isShaded(x: 0, y: 0, parameters: [:]) == true)
        #expect(disk.isShaded(x: 4, y: 0, parameters: [:]) == false)

        let rects = MarchingSquares.extractShadedRects(
            compiled: disk,
            xRange: -5...5,
            yRange: -5...5,
            parameters: [:]
        )
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.xMin >= -3.5 && $0.xMax <= 3.5 })

        // Chained interval inequality (-2 <= x < 3) emits both vertical boundaries
        let strip = try MathExpressionEvaluator.compileGraphEquation("-2 <= x < 3")
        #expect(strip.boundaries.count == 2)
        #expect(strip.hasStrictBoundary)
        #expect(strip.isShaded(x: 0, y: 10, parameters: [:]) == true)
        #expect(strip.isShaded(x: -3, y: 0, parameters: [:]) == false)

        // Snapshot renders inequality PNG without error
        let png = GraphSnapshotRenderer.renderPNG(
            equations: [EquationEntry(expression: "y <= x^2")],
            parameters: [:],
            xRange: -4...4,
            yRange: -4...4,
            keyPoints: []
        )
        #expect(png != nil)
    }

    @Test("Expanded trig, hyperbolic, log2, rounding, multi-arg max/min/mod, and |x| bars evaluate cleanly")
    func expandedFunctionsAndAbsoluteBars() throws {
        let absNode = try MathExpressionEvaluator.parseExpression("2|x - 1| + |y|", allowedVariables: ["x", "y"])
        #expect(abs(absNode.evaluate(x: -2, y: -3) - 9.0) < 1e-9)

        let nestedAbs = try MathExpressionEvaluator.parseExpression("|1 - |x||", allowedVariables: ["x"])
        #expect(abs(nestedAbs.evaluate(x: -4, y: 0) - 3.0) < 1e-9)

        let hyper = try MathExpressionEvaluator.parseExpression("sinh(0) + cosh(0) + tanh(0)", allowedVariables: ["x"])
        #expect(abs(hyper.evaluate(x: 0, y: 0) - 1.0) < 1e-9)

        let logNode = try MathExpressionEvaluator.parseExpression("log2(8) + csc(pi/2) + sec(0) + floor(2.9) + ceil(1.1)", allowedVariables: ["x"])
        #expect(abs(logNode.evaluate(x: 0, y: 0) - (3.0 + 1.0 + 1.0 + 2.0 + 2.0)) < 1e-9)

        let multi = try MathExpressionEvaluator.parseExpression("max(x, x^2, 2) - min(x, -1) + mod(7, 3)", allowedVariables: ["x"])
        // At x = -2: max(-2, 4, 2) = 4; min(-2, -1) = -2; mod(7, 3) = 1 => 4 - (-2) + 1 = 7
        #expect(abs(multi.evaluate(x: -2, y: 0) - 7.0) < 1e-9)

        // Arbitrary base log(arg, base), base-10 log(100), and ln(e)
        let arbitraryLog = try MathExpressionEvaluator.parseExpression("log(8, 2) + log(100) + ln(e)", allowedVariables: ["x"])
        #expect(abs(arbitraryLog.evaluate(x: 0, y: 0) - 6.0) < 1e-9)

        let paramLog = try MathExpressionEvaluator.compileGraphEquation("y = log(x, a)")
        #expect(paramLog.freeParameters == ["a"])
        #expect(abs((paramLog.explicitAST?.evaluate(x: 27, y: 0, parameters: ["a": 3]) ?? 0) - 3.0) < 1e-9)
    }

    @Test("Golden ratio phi/φ constant and subscript log_b(x) evaluate without spurious parameters")
    func goldenRatioAndSubscriptLog() throws {
        let phi = (1.0 + Darwin.sqrt(5.0)) * 0.5
        let compiledPhi = try MathExpressionEvaluator.compileGraphEquation("y = phi * x + 2φ")
        #expect(compiledPhi.freeParameters.isEmpty)
        #expect(abs((compiledPhi.explicitAST?.evaluate(x: 1, y: 0) ?? 0) - (3.0 * phi)) < 1e-9)

        let subLogNum = try MathExpressionEvaluator.parseExpression("log_2(8) + log_(2+2)(16) + 2log_3(9)", allowedVariables: ["x"])
        // 3 + 2 + 2*2 = 9
        #expect(abs(subLogNum.evaluate(x: 0, y: 0) - 9.0) < 1e-9)

        let subLogParam = try MathExpressionEvaluator.compileGraphEquation("y = log_a(x)")
        #expect(subLogParam.freeParameters == ["a"])
        #expect(abs((subLogParam.explicitAST?.evaluate(x: 81, y: 0, parameters: ["a": 3]) ?? 0) - 4.0) < 1e-9)
    }
}
