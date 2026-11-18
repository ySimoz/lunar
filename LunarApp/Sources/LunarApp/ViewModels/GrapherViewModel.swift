import Foundation
import Observation

/// Active sub-tab inside the Tools workspace.
public enum ToolsTab: String, CaseIterable, Identifiable, Sendable {
    case focusTimer = "Focus Timer"
    case grapher = "2D Grapher"

    public var id: String { rawValue }
}

/// Single equation entry in the 2D Grapher sidebar.
public struct EquationEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var expression: String
    public var isVisible: Bool
    public var colorIndex: Int

    public init(
        id: UUID = UUID(),
        expression: String,
        isVisible: Bool = true,
        colorIndex: Int = 0
    ) {
        self.id = id
        self.expression = expression
        self.isVisible = isVisible
        self.colorIndex = colorIndex
    }
}

/// Single CAS console input/output entry (`(%iN)` / `(%oN)`).
public struct CASHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let rawInput: String
    public let outputLatex: String
    public let plottableExpression: String?
    public let isError: Bool

    public init(
        id: UUID = UUID(),
        index: Int,
        rawInput: String,
        outputLatex: String,
        plottableExpression: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.index = index
        self.rawInput = rawInput
        self.outputLatex = outputLatex
        self.plottableExpression = plottableExpression
        self.isError = isError
    }
}

/// Editable scalar parameter definition (`a`, `b`, `k`, ...) discovered in plotted equations.
public struct GraphParameter: Identifiable, Equatable, Sendable {
    public let name: Character
    public var value: Double
    public var min: Double
    public var max: Double
    public var step: Double

    public var id: Character { name }

    public init(
        name: Character,
        value: Double = 1.0,
        min: Double = -10.0,
        max: Double = 10.0,
        step: Double = 0.1
    ) {
        self.name = name
        let safeMin = min.isFinite ? min : -10.0
        let safeMax = (max.isFinite && max > safeMin) ? max : safeMin + 20.0
        self.min = safeMin
        self.max = safeMax
        self.step = (step.isFinite && step > 0) ? step : 0.1
        let safeVal = value.isFinite ? value : 1.0
        self.value = Swift.min(safeMax, Swift.max(safeMin, safeVal))
    }

    public var validatedRange: ClosedRange<Double> {
        let upper = max > min ? max : min + 1.0
        return min...upper
    }

    public var validatedStep: Double {
        let span = validatedRange.upperBound - validatedRange.lowerBound
        let candidate = (step.isFinite && step > 0) ? step : 0.1
        return Swift.min(candidate, span)
    }
}

/// Session-scoped state for Tools (`Focus Timer` | `2D Grapher`),
/// starting empty on each fresh app launch while preserving equations, viewport, and CAS history across tab switches.
@Observable
@MainActor
public final class GrapherViewModel {
    public var activeToolTab: ToolsTab = .focusTimer
    public var equations: [EquationEntry] = [] {
        didSet { syncParametersFromEquations() }
    }
    public var parameters: [GraphParameter] = []
    public var selectedKeyPointID: String?
    public var centerX: Double = 0
    public var centerY: Double = 0
    public var halfWidth: Double = 8.0

    public var casInput: String = ""
    public var casHistory: [CASHistoryEntry] = []
    public var isConsoleExpanded: Bool = true
    public var nextCASIndex: Int = 1

    public init() {}

    public var parameterEnvironment: [Character: Double] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.value) })
    }

    public func syncParametersFromEquations() {
        var orderedNames: [Character] = []
        var seen = Set<Character>()
        for entry in equations {
            for name in MathExpressionEvaluator.extractFreeParameters(from: entry.expression) {
                if seen.insert(name).inserted {
                    orderedNames.append(name)
                }
            }
        }

        if parameters.map(\.name) == orderedNames {
            return
        }

        let existingByName = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0) })
        parameters = orderedNames.map { name in
            existingByName[name] ?? GraphParameter(name: name)
        }
    }

    public func setParameterValue(name: Character, value: Double) {
        guard let idx = parameters.firstIndex(where: { $0.name == name }), value.isFinite else { return }
        let range = parameters[idx].validatedRange
        parameters[idx].value = Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }

    public func updateParameterBounds(name: Character, min: Double, max: Double, step: Double) {
        guard let idx = parameters.firstIndex(where: { $0.name == name }) else { return }
        let safeMin = min.isFinite ? min : -10.0
        let safeMax = (max.isFinite && max > safeMin) ? max : safeMin + 1.0
        let safeStep = (step.isFinite && step > 0) ? step : 0.1
        parameters[idx].min = safeMin
        parameters[idx].max = safeMax
        parameters[idx].step = safeStep
        parameters[idx].value = Swift.min(safeMax, Swift.max(safeMin, parameters[idx].value))
    }

    public func resetParameter(name: Character) {
        guard let idx = parameters.firstIndex(where: { $0.name == name }) else { return }
        parameters[idx] = GraphParameter(name: name)
    }

    public func viewportRanges(aspect: Double = 0.7) -> (xRange: ClosedRange<Double>, yRange: ClosedRange<Double>) {
        let safeAspect = (aspect.isFinite && aspect > 0.05) ? aspect : 0.7
        let xRange = (centerX - halfWidth)...(centerX + halfWidth)
        let halfHeight = halfWidth * safeAspect
        let yRange = (centerY - halfHeight)...(centerY + halfHeight)
        return (xRange, yRange)
    }

    public func visibleKeyPoints(aspect: Double = 0.7) -> [GraphKeyPoint] {
        let (xRange, yRange) = viewportRanges(aspect: aspect)
        let visible = equations
            .filter(\.isVisible)
            .map { (id: $0.id, expression: $0.expression) }
        return GraphFeatureSolver.findKeyPoints(
            equations: visible,
            parameters: parameterEnvironment,
            xRange: xRange,
            yRange: yRange
        )
    }

    public func nearestKeyPoint(
        toWorldX wx: Double,
        worldY wy: Double,
        aspect: Double = 0.7,
        maxNormalizedDistance: Double = 0.032,
        from keyPoints: [GraphKeyPoint]? = nil
    ) -> GraphKeyPoint? {
        let (xRange, yRange) = viewportRanges(aspect: aspect)
        let xSpan = max(1e-9, xRange.upperBound - xRange.lowerBound)
        let ySpan = max(1e-9, yRange.upperBound - yRange.lowerBound)
        let points = keyPoints ?? visibleKeyPoints(aspect: aspect)

        var bestPoint: GraphKeyPoint?
        var bestDist = maxNormalizedDistance

        for pt in points {
            let dx = (pt.x - wx) / xSpan
            let dy = (pt.y - wy) / ySpan
            let dist = hypot(dx, dy)
            if dist < bestDist - 1e-6 {
                bestDist = dist
                bestPoint = pt
            } else if abs(dist - bestDist) <= 1e-6,
                      let currentBest = bestPoint,
                      pt.kind.snapPriority > currentBest.kind.snapPriority {
                bestPoint = pt
            }
        }
        return bestPoint
    }

    public func addEmptyEquation() {
        let nextColor = (equations.map(\.colorIndex).max() ?? -1) + 1
        equations.append(EquationEntry(expression: "", isVisible: true, colorIndex: nextColor))
    }

    public func removeEquation(id: UUID) {
        equations.removeAll { $0.id == id }
    }

    public func addPlottedEquation(_ expression: String) {
        let normalized = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        if !equations.contains(where: { $0.expression.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) {
            let nextColor = (equations.map(\.colorIndex).max() ?? -1) + 1
            equations.append(EquationEntry(
                expression: normalized,
                isVisible: true,
                colorIndex: nextColor
            ))
        }
    }

    public func submitCAS() {
        let trimmed = casInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let index = nextCASIndex
        nextCASIndex += 1
        casInput = ""
        isConsoleExpanded = true

        do {
            let result = try MathExpressionEvaluator.evaluateCAS(trimmed)
            if result.shouldAutoPlot, let expr = result.plottableExpression {
                addPlottedEquation(expr)
            }
            casHistory.append(CASHistoryEntry(
                index: index,
                rawInput: trimmed,
                outputLatex: result.outputLatex,
                plottableExpression: result.shouldAutoPlot ? nil : result.plottableExpression,
                isError: false
            ))
        } catch {
            casHistory.append(CASHistoryEntry(
                index: index,
                rawInput: trimmed,
                outputLatex: error.localizedDescription,
                plottableExpression: nil,
                isError: true
            ))
        }
    }

    public func resetViewport() {
        centerX = 0
        centerY = 0
        halfWidth = 8.0
    }

    /// Zooms the 2D grapher viewport around normalized canvas coordinates (`0...1`, top-left origin).
    public func zoom(
        scaleFactor: Double,
        anchorNormalizedX: Double = 0.5,
        anchorNormalizedY: Double = 0.5,
        aspect: Double = 0.7
    ) {
        let clampedFactor = min(2.0, max(0.25, scaleFactor))
        let newHalfWidth = min(250.0, max(0.25, halfWidth * clampedFactor))
        let oldHalfHeight = halfWidth * aspect
        let newHalfHeight = newHalfWidth * aspect

        let wx = centerX + (anchorNormalizedX - 0.5) * 2.0 * halfWidth
        let wy = centerY + (0.5 - anchorNormalizedY) * 2.0 * oldHalfHeight

        halfWidth = newHalfWidth
        centerX = wx - (anchorNormalizedX - 0.5) * 2.0 * newHalfWidth
        centerY = wy - (0.5 - anchorNormalizedY) * 2.0 * newHalfHeight
    }

    public nonisolated static func formatAxisValue(_ value: Double, step: Double) -> String {
        if abs(value) < max(1e-9, step * 1e-4) {
            return "0"
        }
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if abs(rounded - rounded.rounded()) < 1e-6 {
            return String(Int(rounded.rounded()))
        }
        if step >= 0.1 {
            return String(format: "%.1f", rounded)
        }
        return String(format: "%.2f", rounded)
    }
}
