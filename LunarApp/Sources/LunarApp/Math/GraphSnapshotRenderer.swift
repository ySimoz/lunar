import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Pre-filled flashcard draft generated from the current 2D Grapher state.
public struct GraphCardDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let front: String
    public let back: String
    public let explanation: String
    public let tags: [String]
    public let cardType: CardType
    public let imageDataURI: String
    public let pngByteCount: Int

    public init(
        id: UUID = UUID(),
        front: String,
        back: String,
        explanation: String,
        tags: [String] = ["grapher"],
        cardType: CardType = .example,
        imageDataURI: String,
        pngByteCount: Int
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.explanation = explanation
        self.tags = tags
        self.cardType = cardType
        self.imageDataURI = imageDataURI
        self.pngByteCount = pngByteCount
    }
}

/// Renders a crisp, compact monochrome PNG diagram of plotted 2D curves and key points.
public enum GraphSnapshotRenderer {
    public struct SnapshotPayload: Sendable, Equatable {
        public let pngData: Data
        public let dataURI: String
    }

    public static func renderPNG(
        equations: [EquationEntry],
        parameters: [Character: Double],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        isDark: Bool = false,
        width: Int = 560,
        height: Int = 350
    ) -> SnapshotPayload? {
        guard width > 40, height > 40 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let w = CGFloat(width)
        let h = CGFloat(height)

        let bgColor = isDark
            ? CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
            : CGColor(red: 0.98, green: 0.98, blue: 0.985, alpha: 1.0)
        let gridColor = isDark
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.07)
            : CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.07)
        let axisColor = isDark
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 0.28)
            : CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.28)
        let labelColor = isDark
            ? NSColor(white: 1.0, alpha: 0.58)
            : NSColor(white: 0.12, alpha: 0.62)

        ctx.setFillColor(bgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let xSpan = max(1e-9, xRange.upperBound - xRange.lowerBound)
        let ySpan = max(1e-9, yRange.upperBound - yRange.lowerBound)

        func toCanvas(_ wx: Double, _ wy: Double) -> CGPoint {
            let nx = (wx - xRange.lowerBound) / xSpan
            let ny = (wy - yRange.lowerBound) / ySpan
            return CGPoint(x: CGFloat(nx) * w, y: CGFloat(ny) * h)
        }

        // Gridlines
        let step = niceGridStep(span: xSpan)
        ctx.setStrokeColor(gridColor)
        ctx.setLineWidth(1.0)
        let firstX = ceil(xRange.lowerBound / step) * step
        var gx = firstX
        while gx <= xRange.upperBound {
            let sx = toCanvas(gx, 0).x
            ctx.move(to: CGPoint(x: sx, y: 0))
            ctx.addLine(to: CGPoint(x: sx, y: h))
            gx += step
        }
        let firstY = ceil(yRange.lowerBound / step) * step
        var gy = firstY
        while gy <= yRange.upperBound {
            let sy = toCanvas(0, gy).y
            ctx.move(to: CGPoint(x: 0, y: sy))
            ctx.addLine(to: CGPoint(x: w, y: sy))
            gy += step
        }
        ctx.strokePath()

        // Axes
        ctx.setStrokeColor(axisColor)
        ctx.setLineWidth(1.2)
        if xRange.contains(0) {
            let x0 = toCanvas(0, 0).x
            ctx.move(to: CGPoint(x: x0, y: 0))
            ctx.addLine(to: CGPoint(x: x0, y: h))
        }
        if yRange.contains(0) {
            let y0 = toCanvas(0, 0).y
            ctx.move(to: CGPoint(x: 0, y: y0))
            ctx.addLine(to: CGPoint(x: w, y: y0))
        }
        ctx.strokePath()

        // Axis ticks and numeric labels
        let rawOrigin = toCanvas(0, 0)
        let tickY = min(max(rawOrigin.y, 18), h - 14)
        let tickX = min(max(rawOrigin.x, 30), w - 12)
        let xAxisVisible = (0...h).contains(rawOrigin.y)
        let yAxisVisible = (0...w).contains(rawOrigin.x)
        let labelFont = CTFontCreateWithName("Menlo" as CFString, 9.5, nil)

        func drawLabel(_ text: String, at point: CGPoint, alignRight: Bool = false) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: labelColor
            ]
            let attr = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let drawX = alignRight ? (point.x - bounds.width) : (point.x - bounds.width * 0.5)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: drawX, y: point.y)
            CTLineDraw(line, ctx)
        }

        var tx = firstX
        while tx <= xRange.upperBound {
            let sx = toCanvas(tx, 0).x
            if xAxisVisible {
                ctx.setStrokeColor(axisColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: sx, y: rawOrigin.y - 3))
                ctx.addLine(to: CGPoint(x: sx, y: rawOrigin.y + 3))
                ctx.strokePath()
            }
            if abs(tx) >= step * 1e-4 && sx > 22 && sx < w - 18 {
                let text = GrapherViewModel.formatAxisValue(tx, step: step)
                drawLabel(text, at: CGPoint(x: sx, y: tickY - 13))
            }
            tx += step
        }

        var ty = firstY
        while ty <= yRange.upperBound {
            let sy = toCanvas(0, ty).y
            if yAxisVisible {
                ctx.setStrokeColor(axisColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: rawOrigin.x - 3, y: sy))
                ctx.addLine(to: CGPoint(x: rawOrigin.x + 3, y: sy))
                ctx.strokePath()
            }
            if abs(ty) >= step * 1e-4 && sy > 14 && sy < h - 14 {
                let text = GrapherViewModel.formatAxisValue(ty, step: step)
                drawLabel(text, at: CGPoint(x: tickX - 6, y: sy - 3.5), alignRight: true)
            }
            ty += step
        }

        // Plotted curves
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.0)

        for entry in equations where entry.isVisible {
            guard let ast = try? MathExpressionEvaluator.compileEquation(entry.expression, allowFreeParameters: true) else {
                continue
            }
            let segments = MarchingSquares.extractSegments(
                ast: ast,
                xRange: xRange,
                yRange: yRange,
                parameters: parameters
            )
            ctx.setStrokeColor(curveCGColor(for: entry.colorIndex, isDark: isDark))
            ctx.beginPath()
            for seg in segments {
                let p1 = toCanvas(seg.x1, seg.y1)
                let p2 = toCanvas(seg.x2, seg.y2)
                ctx.move(to: p1)
                ctx.addLine(to: p2)
            }
            ctx.strokePath()
        }

        // Key point markers
        let markerStroke = isDark
            ? CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 0.90)
            : CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 0.90)

        for point in keyPoints {
            let pt = toCanvas(point.x, point.y)
            guard pt.x >= -4, pt.x <= w + 4, pt.y >= -4, pt.y <= h + 4 else { continue }
            let r: CGFloat = (point.kind == .intersection) ? 4.0 : 3.5
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)

            if point.kind == .intersection {
                ctx.setFillColor(markerStroke)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(bgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: rect.insetBy(dx: -0.75, dy: -0.75))
            } else {
                ctx.setFillColor(bgColor)
                ctx.fillEllipse(in: rect)
                ctx.setStrokeColor(markerStroke)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: rect)
            }
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let base64 = pngData.base64EncodedString()
        let dataURI = "data:image/png;base64,\(base64)"
        return SnapshotPayload(pngData: pngData, dataURI: dataURI)
    }

    private static func niceGridStep(span: Double) -> Double {
        let raw = span / 10.0
        let exp = floor(log10(max(1e-6, raw)))
        let base = pow(10.0, exp)
        let frac = raw / base
        if frac < 1.5 { return base }
        if frac < 3.5 { return 2.0 * base }
        if frac < 7.5 { return 5.0 * base }
        return 10.0 * base
    }

    private static func curveCGColor(for index: Int, isDark: Bool) -> CGColor {
        let palette: [CGColor] = isDark
            ? [
                CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1.0),
                CGColor(red: 148 / 255, green: 163 / 255, blue: 184 / 255, alpha: 1.0),
                CGColor(red: 130 / 255, green: 158 / 255, blue: 184 / 255, alpha: 1.0),
                CGColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1.0),
                CGColor(red: 176 / 255, green: 190 / 255, blue: 204 / 255, alpha: 1.0)
            ]
            : [
                CGColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0),
                CGColor(red: 71 / 255, green: 85 / 255, blue: 105 / 255, alpha: 1.0),
                CGColor(red: 56 / 255, green: 86 / 255, blue: 118 / 255, alpha: 1.0),
                CGColor(red: 0.44, green: 0.44, blue: 0.46, alpha: 1.0),
                CGColor(red: 92 / 255, green: 110 / 255, blue: 128 / 255, alpha: 1.0)
            ]
        return palette[abs(index) % palette.count]
    }
}

/// Builds pre-filled flashcard Markdown + LaTeX + PNG diagram payloads from 2D Grapher state.
public enum GraphCardDraftBuilder {
    public static func build(
        equations: [EquationEntry],
        parameters: [GraphParameter],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        isDark: Bool = false
    ) -> GraphCardDraft? {
        let visibleEquations = equations.filter {
            $0.isVisible && !$0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !visibleEquations.isEmpty else { return nil }

        let paramMap = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value) })
        guard let snapshot = GraphSnapshotRenderer.renderPNG(
            equations: visibleEquations,
            parameters: paramMap,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            isDark: isDark
        ) else {
            return nil
        }

        let equationLines = visibleEquations.map { entry in
            let expr = entry.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            if let explicit = MathExpressionEvaluator.parseExplicitFunction(expr) {
                return "- $y = \(explicit.toLaTeX())$"
            }
            let parts = expr.components(separatedBy: "=")
            if parts.count == 2,
               let lhs = try? MathExpressionEvaluator.parseExpression(
                   parts[0],
                   allowedVariables: MathExpressionEvaluator.defaultGraphAllowedVariables
               ),
               let rhs = try? MathExpressionEvaluator.parseExpression(
                   parts[1],
                   allowedVariables: MathExpressionEvaluator.defaultGraphAllowedVariables
               ) {
                return "- $\(lhs.toLaTeX()) = \(rhs.toLaTeX())$"
            }
            return "- `\(expr)`"
        }

        var frontParts: [String] = ["Analyze the graph and key intercepts for:"]
        frontParts.append(equationLines.joined(separator: "\n"))
        if !parameters.isEmpty {
            let paramText = parameters
                .map { "$\($0.name) = \(GraphFeatureSolver.formatCoordinate($0.value))$" }
                .joined(separator: ", ")
            frontParts.append("Parameters: \(paramText)")
        }
        let front = frontParts.joined(separator: "\n\n")

        var backParts: [String] = ["![2D Graph](\(snapshot.dataURI))"]
        let summaryLines = formatKeyPointSummary(keyPoints, limitPerKind: 4)
        if !summaryLines.isEmpty {
            backParts.append(summaryLines.joined(separator: "\n"))
        }
        let back = backParts.joined(separator: "\n\n")

        var noteLines: [String] = [
            "Viewport: $x \\in [\(GraphFeatureSolver.formatCoordinate(xRange.lowerBound)), \(GraphFeatureSolver.formatCoordinate(xRange.upperBound))]$, $y \\in [\(GraphFeatureSolver.formatCoordinate(yRange.lowerBound)), \(GraphFeatureSolver.formatCoordinate(yRange.upperBound))]$"
        ]
        if !parameters.isEmpty {
            let paramSummary = parameters
                .map { "`\($0.name) = \(GraphFeatureSolver.formatCoordinate($0.value))`" }
                .joined(separator: ", ")
            noteLines.append("Parameters: \(paramSummary)")
        }
        let fullPoints = formatKeyPointSummary(keyPoints, limitPerKind: 12)
        if !fullPoints.isEmpty {
            noteLines.append(contentsOf: fullPoints)
        }
        let explanation = noteLines.joined(separator: "\n\n")

        return GraphCardDraft(
            front: front,
            back: back,
            explanation: explanation,
            tags: ["grapher"],
            cardType: .example,
            imageDataURI: snapshot.dataURI,
            pngByteCount: snapshot.pngData.count
        )
    }

    private static func formatKeyPointSummary(
        _ keyPoints: [GraphKeyPoint],
        limitPerKind: Int
    ) -> [String] {
        var lines: [String] = []

        let xInts = keyPoints.filter { $0.kind == .xIntercept }.prefix(limitPerKind)
        if !xInts.isEmpty {
            let coords = xInts.map { GraphFeatureSolver.formatPoint(x: $0.x, y: $0.y) }.joined(separator: ", ")
            lines.append("- x-intercepts: \(coords)")
        }

        let yInts = keyPoints.filter { $0.kind == .yIntercept }.prefix(limitPerKind)
        if !yInts.isEmpty {
            let coords = yInts.map { GraphFeatureSolver.formatPoint(x: $0.x, y: $0.y) }.joined(separator: ", ")
            lines.append("- y-intercepts: \(coords)")
        }

        let inters = keyPoints.filter { $0.kind == .intersection }.prefix(limitPerKind)
        if !inters.isEmpty {
            let coords = inters.map { GraphFeatureSolver.formatPoint(x: $0.x, y: $0.y) }.joined(separator: ", ")
            lines.append("- Intersections: \(coords)")
        }

        return lines
    }
}
