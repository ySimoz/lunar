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

/// Session-scoped state for Tools (`Focus Timer` | `2D Grapher`),
/// starting empty on each fresh app launch while preserving equations, viewport, and CAS history across tab switches.
@Observable
@MainActor
public final class GrapherViewModel {
    public var activeToolTab: ToolsTab = .focusTimer
    public var equations: [EquationEntry] = []
    public var centerX: Double = 0
    public var centerY: Double = 0
    public var halfWidth: Double = 8.0

    public var casInput: String = ""
    public var casHistory: [CASHistoryEntry] = []
    public var isConsoleExpanded: Bool = true
    public var nextCASIndex: Int = 1

    public init() {}

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
