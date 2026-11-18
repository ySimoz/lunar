import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Export raster format for external graph snapshots.
public enum GraphImageFormat: String, Sendable {
    case png
    case jpeg

    public var fileExtension: String { rawValue }
}

/// Renders a crisp, compact monochrome diagram of plotted 2D curves and key points.
public enum GraphSnapshotRenderer {
    public struct SnapshotPayload: Sendable, Equatable {
        public let pngData: Data
        public let dataURI: String
    }

    public static func defaultLabel(for equations: [EquationEntry]) -> String {
        let visible = equations
            .map { $0.expression.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !visible.isEmpty else { return "Graph" }
        if visible.count == 1 {
            let expr = String(visible[0].prefix(26))
            return "Graph: \(expr)"
        }
        let joined = visible.prefix(2).joined(separator: ", ")
        if visible.count == 2, joined.count <= 28 {
            return "Graph: \(joined)"
        }
        return "Graph (\(visible.count) functions)"
    }

    public struct ExportViewport: Equatable, Sendable {
        public let xRange: ClosedRange<Double>
        public let yRange: ClosedRange<Double>
        public let width: Int
        public let height: Int
        public let isCropped: Bool
    }

    /// Maps an optional normalized/screen crop rectangle to world bounds and aspect-preserved pixel dimensions.
    public static func resolveExportViewport(
        cropRect: CGRect?,
        canvasSize: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        longestEdge: Int = 560
    ) -> ExportViewport {
        let clampedLongest = max(160, longestEdge)
        let defaultAspect = canvasSize.width > 0 ? max(0.25, min(2.5, Double(canvasSize.height / canvasSize.width))) : 0.625

        guard let rect = cropRect,
              canvasSize.width > 20,
              canvasSize.height > 20,
              rect.width >= 12,
              rect.height >= 12 else {
            let w = clampedLongest
            let h = max(120, Int((Double(w) * defaultAspect).rounded()))
            return ExportViewport(xRange: xRange, yRange: yRange, width: w, height: h, isCropped: false)
        }

        let minNX = max(0.0, min(1.0, Double(rect.minX / canvasSize.width)))
        let maxNX = max(minNX + 0.01, min(1.0, Double(rect.maxX / canvasSize.width)))
        let minNY = max(0.0, min(1.0, Double(rect.minY / canvasSize.height)))
        let maxNY = max(minNY + 0.01, min(1.0, Double(rect.maxY / canvasSize.height)))

        let xSpan = max(1e-9, xRange.upperBound - xRange.lowerBound)
        let ySpan = max(1e-9, yRange.upperBound - yRange.lowerBound)

        let subMinX = xRange.lowerBound + minNX * xSpan
        let subMaxX = xRange.lowerBound + maxNX * xSpan
        let subMaxY = yRange.upperBound - minNY * ySpan
        let subMinY = yRange.upperBound - maxNY * ySpan

        let rectW = max(1.0, Double(rect.width))
        let rectH = max(1.0, Double(rect.height))
        let pixelW: Int
        let pixelH: Int
        if rectW >= rectH {
            pixelW = clampedLongest
            pixelH = max(120, Int((Double(clampedLongest) * (rectH / rectW)).rounded()))
        } else {
            pixelH = clampedLongest
            pixelW = max(120, Int((Double(clampedLongest) * (rectW / rectH)).rounded()))
        }

        return ExportViewport(
            xRange: subMinX...subMaxX,
            yRange: subMinY...subMaxY,
            width: pixelW,
            height: pixelH,
            isCropped: true
        )
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
        guard let pngData = renderImageData(
            equations: equations,
            parameters: parameters,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            format: .png,
            isDark: isDark,
            width: width,
            height: height
        ) else {
            return nil
        }

        let base64 = pngData.base64EncodedString()
        let dataURI = "data:image/png;base64,\(base64)"
        return SnapshotPayload(pngData: pngData, dataURI: dataURI)
    }

    public static func renderImageData(
        equations: [EquationEntry],
        parameters: [Character: Double],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        format: GraphImageFormat = .png,
        isDark: Bool = false,
        width: Int = 1120,
        height: Int = 700
    ) -> Data? {
        guard let rep = renderBitmapRep(
            equations: equations,
            parameters: parameters,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            isDark: isDark,
            width: width,
            height: height
        ) else {
            return nil
        }

        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }

    private static func renderBitmapRep(
        equations: [EquationEntry],
        parameters: [Character: Double],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        isDark: Bool,
        width: Int,
        height: Int
    ) -> NSBitmapImageRep? {
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
            guard let compiled = try? MathExpressionEvaluator.compileGraphEquation(entry.expression, allowFreeParameters: true) else {
                continue
            }
            let baseCGColor = curveCGColor(for: entry.colorIndex, isDark: isDark)

            if compiled.isInequality {
                let fillCGColor = baseCGColor.copy(alpha: 0.18) ?? baseCGColor
                ctx.setFillColor(fillCGColor)
                let rects = MarchingSquares.extractShadedRects(
                    compiled: compiled,
                    xRange: xRange,
                    yRange: yRange,
                    parameters: parameters
                )
                for r in rects {
                    let pMin = toCanvas(r.xMin, r.yMin)
                    let pMax = toCanvas(r.xMax, r.yMax)
                    let cgRect = CGRect(
                        x: min(pMin.x, pMax.x),
                        y: min(pMin.y, pMax.y),
                        width: abs(pMax.x - pMin.x),
                        height: abs(pMax.y - pMin.y)
                    )
                    ctx.fill(cgRect)
                }
            }

            ctx.setStrokeColor(baseCGColor)
            if compiled.hasStrictBoundary {
                ctx.setLineDash(phase: 0, lengths: [5, 4])
                ctx.setLineWidth(1.75)
            } else {
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setLineWidth(2.0)
            }

            for boundaryAST in compiled.boundaries {
                let segments = MarchingSquares.extractSegments(
                    ast: boundaryAST,
                    xRange: xRange,
                    yRange: yRange,
                    parameters: parameters,
                    restrictions: compiled.restrictions
                )
                ctx.beginPath()
                for seg in segments {
                    let p1 = toCanvas(seg.x1, seg.y1)
                    let p2 = toCanvas(seg.x2, seg.y2)
                    ctx.move(to: p1)
                    ctx.addLine(to: p2)
                }
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
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
        return NSBitmapImageRep(cgImage: cgImage)
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
