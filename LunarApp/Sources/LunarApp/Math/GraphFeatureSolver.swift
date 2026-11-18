import Foundation

/// Classification of a notable mathematical point on the 2D grapher canvas.
public enum GraphPointKind: String, Sendable, Equatable, CaseIterable {
    case xIntercept
    case yIntercept
    case intersection

    public var label: String {
        switch self {
        case .xIntercept: "x-intercept"
        case .yIntercept: "y-intercept"
        case .intersection: "Intersection"
        }
    }

    public var snapPriority: Int {
        switch self {
        case .intersection: 3
        case .xIntercept: 2
        case .yIntercept: 1
        }
    }
}

/// Resolved numerical point of interest (`x`-intercept, `y`-intercept, or curve intersection).
public struct GraphKeyPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let kind: GraphPointKind
    public let equationIDs: [UUID]

    public init(
        id: String? = nil,
        x: Double,
        y: Double,
        kind: GraphPointKind,
        equationIDs: [UUID] = []
    ) {
        let cleanX = abs(x) < 1e-9 ? 0.0 : x
        let cleanY = abs(y) < 1e-9 ? 0.0 : y
        self.x = cleanX
        self.y = cleanY
        self.kind = kind
        self.equationIDs = equationIDs
        self.id = id ?? "\(kind.rawValue):\(String(format: "%.6f", cleanX)):\(String(format: "%.6f", cleanY))"
    }
}

/// Pure numerical solver for visible viewport x-intercepts, y-intercepts, and pairwise curve intersections.
public enum GraphFeatureSolver {
    private static let sampleSteps = 320
    private static let rootTolerance = 1e-10
    private static let residualLimit = 1e-6

    /// Finds key points across visible equations within `(xRange, yRange)`.
    public static func findKeyPoints(
        equations: [(id: UUID, expression: String)],
        parameters: [Character: Double],
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        maxPerCategory: Int = 24,
        maxTotal: Int = 64
    ) -> [GraphKeyPoint] {
        let xSpan = xRange.upperBound - xRange.lowerBound
        let ySpan = yRange.upperBound - yRange.lowerBound
        guard xSpan > 1e-9, ySpan > 1e-9, !equations.isEmpty else { return [] }

        struct CompiledCurve {
            let id: UUID
            let compiledEquation: CompiledGraphEquation
            var implicitAST: MathASTNode { compiledEquation.implicitAST }
            var explicitAST: MathASTNode? { compiledEquation.explicitAST }
        }

        let compiled: [CompiledCurve] = equations.compactMap { entry in
            guard let compiledEq = try? MathExpressionEvaluator.compileGraphEquation(entry.expression, allowFreeParameters: true) else {
                return nil
            }
            return CompiledCurve(id: entry.id, compiledEquation: compiledEq)
        }
        guard !compiled.isEmpty else { return [] }

        var xIntercepts: [GraphKeyPoint] = []
        var yIntercepts: [GraphKeyPoint] = []
        var intersections: [GraphKeyPoint] = []

        // 1. x-intercepts: F(x, 0) = 0 (or f(x) = 0 for explicit) when y = 0 is visible
        if yRange.contains(0) {
            for curve in compiled {
                let evalX: (Double) -> Double = { x in
                    if let f = curve.explicitAST {
                        return f.evaluate(x: x, y: 0, parameters: parameters)
                    }
                    return curve.implicitAST.evaluate(x: x, y: 0, parameters: parameters)
                }
                if isIdenticallyZero(evalX, in: xRange) {
                    continue
                }
                let roots = findRoots(of: evalX, in: xRange, ySpan: ySpan, maxCount: maxPerCategory)
                for rx in roots where curve.compiledEquation.satisfiesRestrictions(x: rx, y: 0, parameters: parameters) {
                    xIntercepts.append(GraphKeyPoint(
                        x: rx,
                        y: 0,
                        kind: .xIntercept,
                        equationIDs: [curve.id]
                    ))
                }
            }
        }

        // 2. y-intercepts: x = 0 when x = 0 is visible
        if xRange.contains(0) {
            for curve in compiled {
                if let f = curve.explicitAST {
                    let y0 = f.evaluate(x: 0, y: 0, parameters: parameters)
                    if y0.isFinite && yRange.contains(y0),
                       curve.compiledEquation.satisfiesRestrictions(x: 0, y: y0, parameters: parameters) {
                        yIntercepts.append(GraphKeyPoint(
                            x: 0,
                            y: y0,
                            kind: .yIntercept,
                            equationIDs: [curve.id]
                        ))
                    }
                } else {
                    let evalY: (Double) -> Double = { y in
                        curve.implicitAST.evaluate(x: 0, y: y, parameters: parameters)
                    }
                    if isIdenticallyZero(evalY, in: yRange) {
                        continue
                    }
                    let roots = findRoots(of: evalY, in: yRange, ySpan: xSpan, maxCount: maxPerCategory)
                    for ry in roots where curve.compiledEquation.satisfiesRestrictions(x: 0, y: ry, parameters: parameters) {
                        yIntercepts.append(GraphKeyPoint(
                            x: 0,
                            y: ry,
                            kind: .yIntercept,
                            equationIDs: [curve.id]
                        ))
                    }
                }
            }
        }

        // 3. Pairwise explicit curve intersections: f_i(x) - f_j(x) = 0
        if compiled.count >= 2 {
            for i in 0..<(compiled.count - 1) {
                guard let fi = compiled[i].explicitAST else { continue }
                for j in (i + 1)..<compiled.count {
                    guard let fj = compiled[j].explicitAST else { continue }
                    let diff: (Double) -> Double = { x in
                        fi.evaluate(x: x, y: 0, parameters: parameters) - fj.evaluate(x: x, y: 0, parameters: parameters)
                    }
                    if isIdenticallyZero(diff, in: xRange) {
                        continue
                    }
                    let roots = findRoots(of: diff, in: xRange, ySpan: ySpan, maxCount: maxPerCategory)
                    for rx in roots {
                        let yi = fi.evaluate(x: rx, y: 0, parameters: parameters)
                        let yj = fj.evaluate(x: rx, y: 0, parameters: parameters)
                        guard yi.isFinite, yj.isFinite,
                              abs(yi - yj) < 1e-4,
                              yRange.contains(yi),
                              compiled[i].compiledEquation.satisfiesRestrictions(x: rx, y: yi, parameters: parameters),
                              compiled[j].compiledEquation.satisfiesRestrictions(x: rx, y: yi, parameters: parameters) else {
                            continue
                        }
                        intersections.append(GraphKeyPoint(
                            x: rx,
                            y: yi,
                            kind: .intersection,
                            equationIDs: [compiled[i].id, compiled[j].id]
                        ))
                    }
                }
            }
        }

        let xTol = max(1e-5, xSpan * 1e-4)
        let yTol = max(1e-5, ySpan * 1e-4)

        let combined = deduplicate(
            intersections + xIntercepts + yIntercepts,
            xTol: xTol,
            yTol: yTol
        )
        return Array(combined.prefix(maxTotal))
    }

    /// Finds real roots of `f` inside `range` using uniform sampling, pole filtering, Brent refinement,
    /// and golden-section refinement for tangent (even-multiplicity) zeros.
    public static func findRoots(
        of f: (Double) -> Double,
        in range: ClosedRange<Double>,
        ySpan: Double = 10.0,
        maxCount: Int = 24
    ) -> [Double] {
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = upper - lower
        guard span > 1e-12 else { return [] }

        var samples: [Double] = []
        samples.reserveCapacity(sampleSteps + 2)
        let dx = span / Double(sampleSteps)
        for i in 0...sampleSteps {
            samples.append(lower + Double(i) * dx)
        }
        if range.contains(0.0) && !samples.contains(where: { abs($0) < 1e-12 }) {
            samples.append(0.0)
            samples.sort()
        }

        let values = samples.map(f)
        var roots: [Double] = []
        let dedupeTol = max(1e-5, span * 1e-4)

        func addRoot(_ candidate: Double) {
            let clean = abs(candidate) < 1e-9 ? 0.0 : candidate
            guard clean >= lower - 1e-9, clean <= upper + 1e-9 else { return }
            let val = f(clean)
            guard val.isFinite, abs(val) < residualLimit else { return }
            if !roots.contains(where: { abs($0 - clean) < dedupeTol }) {
                roots.append(clean)
            }
        }

        let jumpThreshold = max(50.0, ySpan * 8.0)

        for i in 0..<(samples.count - 1) {
            if roots.count >= maxCount { break }
            let a = samples[i]
            let b = samples[i + 1]
            let fa = values[i]
            let fb = values[i + 1]
            guard fa.isFinite, fb.isFinite else { continue }

            if abs(fa) < 1e-10 {
                addRoot(a)
                continue
            }
            if abs(fb) < 1e-10 {
                addRoot(b)
                continue
            }

            if fa * fb < 0 {
                let mid = 0.5 * (a + b)
                let fmid = f(mid)
                if abs(fa - fb) > jumpThreshold && (!fmid.isFinite || abs(fmid) > max(abs(fa), abs(fb))) {
                    continue
                }
                if let root = brentRoot(f: f, a: a, b: b, fa: fa, fb: fb) {
                    addRoot(root)
                }
            }
        }

        // Check local minima of |f(x)| for tangent roots (e.g. x^2 = 0)
        if roots.count < maxCount && samples.count >= 3 {
            let tangentThreshold = max(0.05, ySpan * 0.02)
            for i in 1..<(samples.count - 1) {
                if roots.count >= maxCount { break }
                let fa = values[i - 1]
                let fb = values[i]
                let fc = values[i + 1]
                guard fa.isFinite, fb.isFinite, fc.isFinite else { continue }
                let y0 = abs(fa)
                let y1 = abs(fb)
                let y2 = abs(fc)
                if y1 < y0 && y1 < y2 && y1 < tangentThreshold {
                    if let root = goldenSectionMinimumRoot(f: f, a: samples[i - 1], b: samples[i + 1]) {
                        addRoot(root)
                    }
                }
            }
        }

        return roots.sorted()
    }

    /// Brent-Dekker root-finding algorithm on a bracket `[a, b]` with `f(a) * f(b) <= 0`.
    public static func brentRoot(
        f: (Double) -> Double,
        a: Double,
        b: Double,
        fa initialFA: Double? = nil,
        fb initialFB: Double? = nil,
        tol: Double = 1e-10,
        maxIter: Int = 64
    ) -> Double? {
        var a = a
        var b = b
        var fa = initialFA ?? f(a)
        var fb = initialFB ?? f(b)
        guard fa.isFinite, fb.isFinite else { return nil }
        if abs(fa) < 1e-12 { return a }
        if abs(fb) < 1e-12 { return b }
        guard fa * fb < 0 else { return nil }

        if abs(fa) < abs(fb) {
            swap(&a, &b)
            swap(&fa, &fb)
        }

        var c = a
        var fc = fa
        var d = b - a
        var mflag = true

        for _ in 0..<maxIter {
            if abs(fb) < tol || abs(b - a) < tol {
                return b
            }

            var s: Double
            if abs(fa - fc) > 1e-15 && abs(fb - fc) > 1e-15 {
                // Inverse quadratic interpolation
                let t1 = (a * fb * fc) / ((fa - fb) * (fa - fc))
                let t2 = (b * fa * fc) / ((fb - fa) * (fb - fc))
                let t3 = (c * fa * fb) / ((fc - fa) * (fc - fb))
                s = t1 + t2 + t3
            } else {
                // Secant step
                s = b - fb * (b - a) / (fb - fa)
            }

            let loBound = (3.0 * a + b) / 4.0
            let inRange = (s > min(loBound, b)) && (s < max(loBound, b))
            let cond2 = mflag && abs(s - b) >= abs(b - c) * 0.5
            let cond3 = !mflag && abs(s - b) >= abs(c - d) * 0.5
            let cond4 = mflag && abs(b - c) < tol
            let cond5 = !mflag && abs(c - d) < tol

            if !inRange || cond2 || cond3 || cond4 || cond5 || !s.isFinite {
                s = 0.5 * (a + b)
                mflag = true
            } else {
                mflag = false
            }

            let fs = f(s)
            guard fs.isFinite else { return nil }
            d = c
            c = b
            fc = fb

            if fa * fs < 0 {
                b = s
                fb = fs
            } else {
                a = s
                fa = fs
            }

            if abs(fa) < abs(fb) {
                swap(&a, &b)
                swap(&fa, &fb)
            }
        }

        return abs(fb) < residualLimit ? b : nil
    }

    private static func goldenSectionMinimumRoot(
        f: (Double) -> Double,
        a: Double,
        b: Double
    ) -> Double? {
        var lo = a
        var hi = b
        let phi = (Darwin.sqrt(5.0) - 1.0) / 2.0
        var c = hi - phi * (hi - lo)
        var d = lo + phi * (hi - lo)
        var fc = abs(f(c))
        var fd = abs(f(d))

        for _ in 0..<55 {
            if abs(hi - lo) < rootTolerance { break }
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
        return (val.isFinite && abs(val) < residualLimit) ? best : nil
    }

    private static func isIdenticallyZero(_ diff: (Double) -> Double, in range: ClosedRange<Double>) -> Bool {
        let probes = 9
        let span = range.upperBound - range.lowerBound
        var finiteCount = 0
        for i in 0..<probes {
            let x = range.lowerBound + (Double(i) + 0.37) / Double(probes) * span
            let v = diff(x)
            if v.isFinite {
                finiteCount += 1
                if abs(v) > 1e-8 {
                    return false
                }
            }
        }
        return finiteCount >= 3
    }

    private static func deduplicate(
        _ points: [GraphKeyPoint],
        xTol: Double,
        yTol: Double
    ) -> [GraphKeyPoint] {
        var result: [GraphKeyPoint] = []
        for point in points {
            if let existingIdx = result.firstIndex(where: {
                abs($0.x - point.x) < xTol && abs($0.y - point.y) < yTol
            }) {
                if point.kind.snapPriority > result[existingIdx].kind.snapPriority {
                    result[existingIdx] = point
                }
            } else {
                result.append(point)
            }
        }
        return result
    }

    /// Formats a scalar coordinate concisely without trailing zeros or `-0`.
    public static func formatCoordinate(_ value: Double) -> String {
        let cleaned = abs(value) < 1e-9 ? 0.0 : value
        let rounded = (cleaned * 10_000.0).rounded() / 10_000.0
        if abs(rounded) < 1e-9 { return "0" }
        if abs(rounded - rounded.rounded()) < 1e-7 && abs(rounded) < 1e12 {
            return String(Int64(rounded.rounded()))
        }
        var formatted = String(format: "%.4f", rounded)
        while formatted.contains(".") && (formatted.hasSuffix("0") || formatted.hasSuffix(".")) {
            if formatted.hasSuffix(".") {
                formatted.removeLast()
                break
            }
            formatted.removeLast()
        }
        return formatted
    }

    public static func formatPoint(x: Double, y: Double) -> String {
        "(\(formatCoordinate(x)), \(formatCoordinate(y)))"
    }
}
