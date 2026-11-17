import AppKit
import SwiftUI

/// Interactive `HSplitView` 2D math plotter with Marching Squares zero-contour rendering,
/// muted gridlines with axis ticks/numbers, scroll-wheel zoom, pan, hover coordinate readout,
/// and symbolic CAS console.
public struct GrapherView: View {
    @Bindable var grapherVM: GrapherViewModel

    @State private var hoverPoint: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var dragStartCenter: (x: Double, y: Double)?
    @State private var scrollMonitor: Any?

    @Environment(\.colorScheme) private var colorScheme

    public init(grapherVM: GrapherViewModel) {
        self.grapherVM = grapherVM
    }

    public var body: some View {
        HSplitView {
            equationSidebar
                .frame(minWidth: 230, idealWidth: 265, maxWidth: 340)

            VStack(spacing: 0) {
                plotterPane
                    .frame(minHeight: 260, maxHeight: .infinity)

                Divider()

                casConsolePane
            }
            .frame(minWidth: 420)
        }
    }

    // MARK: - Equation List

    private var equationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Equations")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    grapherVM.addEmptyEquation()
                } label: {
                    Label("Add Equation", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            .padding(LunarTokens.space4)

            Divider()

            ScrollView {
                if !grapherVM.equations.isEmpty {
                    VStack(spacing: LunarTokens.space2) {
                        ForEach($grapherVM.equations) { $entry in
                            EquationRow(
                                entry: $entry,
                                curveColor: curveColor(for: entry.colorIndex),
                                onDelete: {
                                    grapherVM.removeEquation(id: entry.id)
                                }
                            )
                        }
                    }
                    .padding(LunarTokens.space3)
                }
            }
        }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
    }

    // MARK: - 2D Canvas Plotter

    private var plotterPane: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let size = proxy.size
                let aspect = size.width > 0 ? (size.height / size.width) : 0.7
                let xRange = (grapherVM.centerX - grapherVM.halfWidth)...(grapherVM.centerX + grapherVM.halfWidth)
                let halfHeight = grapherVM.halfWidth * Double(aspect)
                let yRange = (grapherVM.centerY - halfHeight)...(grapherVM.centerY + halfHeight)

                Canvas { context, canvas in
                    drawGridAndAxes(
                        in: &context,
                        size: canvas,
                        xRange: xRange,
                        yRange: yRange
                    )

                    for entry in grapherVM.equations where entry.isVisible {
                        guard let ast = try? MathExpressionEvaluator.compileEquation(entry.expression) else {
                            continue
                        }
                        let segments = MarchingSquares.extractSegments(
                            ast: ast,
                            xRange: xRange,
                            yRange: yRange
                        )
                        var path = Path()
                        for seg in segments {
                            let p1 = worldToScreen(x: seg.x1, y: seg.y1, size: canvas, xRange: xRange, yRange: yRange)
                            let p2 = worldToScreen(x: seg.x2, y: seg.y2, size: canvas, xRange: xRange, yRange: yRange)
                            path.move(to: p1)
                            path.addLine(to: p2)
                        }
                        context.stroke(
                            path,
                            with: .color(curveColor(for: entry.colorIndex)),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                .background(colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.97))
                .onAppear { canvasSize = size }
                .onChange(of: size) { _, newSize in canvasSize = newSize }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverPoint = location
                    case .ended:
                        hoverPoint = nil
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartCenter == nil {
                                dragStartCenter = (grapherVM.centerX, grapherVM.centerY)
                            }
                            guard let start = dragStartCenter, size.width > 0, size.height > 0 else { return }
                            let worldPerPixelX = (2.0 * grapherVM.halfWidth) / Double(size.width)
                            let worldPerPixelY = (2.0 * halfHeight) / Double(size.height)
                            grapherVM.centerX = start.x - Double(value.translation.width) * worldPerPixelX
                            grapherVM.centerY = start.y + Double(value.translation.height) * worldPerPixelY
                        }
                        .onEnded { _ in
                            dragStartCenter = nil
                        }
                )
                .onAppear {
                    installScrollWheelZoomMonitor()
                }
                .onDisappear {
                    removeScrollWheelZoomMonitor()
                }
            }

            VStack(alignment: .trailing, spacing: LunarTokens.space2) {
                HStack(spacing: 4) {
                    Button {
                        let aspect = canvasSize.width > 0 ? Double(canvasSize.height / canvasSize.width) : 0.7
                        grapherVM.zoom(scaleFactor: 0.75, aspect: aspect)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom In")

                    Button {
                        let aspect = canvasSize.width > 0 ? Double(canvasSize.height / canvasSize.width) : 0.7
                        grapherVM.zoom(scaleFactor: 1.0 / 0.75, aspect: aspect)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom Out")

                    Button("Reset") {
                        grapherVM.resetViewport()
                    }
                }
                .buttonStyle(.bordered)
                .padding(LunarTokens.space2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                        .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                }

                if let hover = hoverPoint, canvasSize.width > 0, canvasSize.height > 0 {
                    let aspect = Double(canvasSize.height / canvasSize.width)
                    let xRange = (grapherVM.centerX - grapherVM.halfWidth)...(grapherVM.centerX + grapherVM.halfWidth)
                    let halfHeight = grapherVM.halfWidth * aspect
                    let yRange = (grapherVM.centerY - halfHeight)...(grapherVM.centerY + halfHeight)
                    let wx = xRange.lowerBound + (Double(hover.x) / Double(canvasSize.width)) * (xRange.upperBound - xRange.lowerBound)
                    let wy = yRange.upperBound - (Double(hover.y) / Double(canvasSize.height)) * (yRange.upperBound - yRange.lowerBound)

                    Text(String(format: "(%.2f, %.2f)", wx, wy))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, LunarTokens.space2)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                        }
                }
            }
            .padding(LunarTokens.space4)
        }
    }

    // MARK: - Symbolic CAS Console

    private var casConsolePane: some View {
        VStack(spacing: 0) {
            if grapherVM.isConsoleExpanded && !grapherVM.casHistory.isEmpty {
                HStack(spacing: LunarTokens.space2) {
                    Text("Console")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("\(grapherVM.casHistory.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Clear") {
                        grapherVM.casHistory.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    Button {
                        withAnimation(LunarTokens.revealAnimation) {
                            grapherVM.isConsoleExpanded = false
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Collapse Console")
                }
                .padding(.horizontal, LunarTokens.space4)
                .padding(.vertical, LunarTokens.space2)
                .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: LunarTokens.space2) {
                            ForEach(grapherVM.casHistory) { entry in
                                CASHistoryRow(entry: entry) { expr in
                                    grapherVM.addPlottedEquation(expr)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, LunarTokens.space4)
                        .padding(.vertical, LunarTokens.space2)
                    }
                    .frame(height: 168)
                    .onChange(of: grapherVM.casHistory.count) { _, _ in
                        if let lastId = grapherVM.casHistory.last?.id {
                            withAnimation(LunarTokens.revealAnimation) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()
            }

            HStack(spacing: LunarTokens.space3) {
                Text("(%i\(grapherVM.nextCASIndex))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                TextField("", text: $grapherVM.casInput)
                    .accessibilityLabel("CAS Input")
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        grapherVM.submitCAS()
                    }

                if !grapherVM.casHistory.isEmpty && !grapherVM.isConsoleExpanded {
                    Button {
                        withAnimation(LunarTokens.revealAnimation) {
                            grapherVM.isConsoleExpanded = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("History (\(grapherVM.casHistory.count))")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                Button("Run") {
                    grapherVM.submitCAS()
                }
                .buttonStyle(MonochromeProminentButtonStyle(compact: true))
                .disabled(grapherVM.casInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, LunarTokens.space4)
            .padding(.vertical, LunarTokens.space3)
            .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
        }
    }

    // MARK: - Grid & Coordinate Helpers

    private func drawGridAndAxes(
        in context: inout GraphicsContext,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) {
        let step = niceGridStep(span: xRange.upperBound - xRange.lowerBound)
        let gridColor = Color.primary.opacity(0.06)
        let axisColor = Color.primary.opacity(0.24)

        var gridPath = Path()
        let firstX = ceil(xRange.lowerBound / step) * step
        var x = firstX
        while x <= xRange.upperBound {
            let sx = worldToScreen(x: x, y: 0, size: size, xRange: xRange, yRange: yRange).x
            gridPath.move(to: CGPoint(x: sx, y: 0))
            gridPath.addLine(to: CGPoint(x: sx, y: size.height))
            x += step
        }

        let firstY = ceil(yRange.lowerBound / step) * step
        var y = firstY
        while y <= yRange.upperBound {
            let sy = worldToScreen(x: 0, y: y, size: size, xRange: xRange, yRange: yRange).y
            gridPath.move(to: CGPoint(x: 0, y: sy))
            gridPath.addLine(to: CGPoint(x: size.width, y: sy))
            y += step
        }
        context.stroke(gridPath, with: .color(gridColor), lineWidth: 1)

        var axisPath = Path()
        if xRange.contains(0) {
            let x0 = worldToScreen(x: 0, y: 0, size: size, xRange: xRange, yRange: yRange).x
            axisPath.move(to: CGPoint(x: x0, y: 0))
            axisPath.addLine(to: CGPoint(x: x0, y: size.height))
        }
        if yRange.contains(0) {
            let y0 = worldToScreen(x: 0, y: 0, size: size, xRange: xRange, yRange: yRange).y
            axisPath.move(to: CGPoint(x: 0, y: y0))
            axisPath.addLine(to: CGPoint(x: size.width, y: y0))
        }
        context.stroke(axisPath, with: .color(axisColor), lineWidth: 1.2)

        // Axis tick marks ("indentations") and numeric coordinates
        let rawOrigin = worldToScreen(x: 0, y: 0, size: size, xRange: xRange, yRange: yRange)
        let tickY = min(max(rawOrigin.y, 12), size.height - 20)
        let tickX = min(max(rawOrigin.x, 28), size.width - 12)
        let labelColor = Color.primary.opacity(0.55)
        let tickColor = Color.primary.opacity(0.35)
        let xAxisVisible = (0...size.height).contains(rawOrigin.y)
        let yAxisVisible = (0...size.width).contains(rawOrigin.x)

        var tickPath = Path()
        var tx = firstX
        while tx <= xRange.upperBound {
            let sx = worldToScreen(x: tx, y: 0, size: size, xRange: xRange, yRange: yRange).x
            if xAxisVisible {
                tickPath.move(to: CGPoint(x: sx, y: rawOrigin.y - 3.5))
                tickPath.addLine(to: CGPoint(x: sx, y: rawOrigin.y + 3.5))
            }
            if abs(tx) >= step * 1e-4 && sx > 22 && sx < size.width - 18 {
                let text = Text(GrapherViewModel.formatAxisValue(tx, step: step))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(labelColor)
                context.draw(text, at: CGPoint(x: sx, y: tickY + 11), anchor: .center)
            }
            tx += step
        }

        var ty = firstY
        while ty <= yRange.upperBound {
            let sy = worldToScreen(x: 0, y: ty, size: size, xRange: xRange, yRange: yRange).y
            if yAxisVisible {
                tickPath.move(to: CGPoint(x: rawOrigin.x - 3.5, y: sy))
                tickPath.addLine(to: CGPoint(x: rawOrigin.x + 3.5, y: sy))
            }
            if abs(ty) >= step * 1e-4 && sy > 12 && sy < size.height - 16 {
                let text = Text(GrapherViewModel.formatAxisValue(ty, step: step))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(labelColor)
                context.draw(text, at: CGPoint(x: tickX - 6, y: sy), anchor: .trailing)
            }
            ty += step
        }
        context.stroke(tickPath, with: .color(tickColor), lineWidth: 1)

        if xAxisVisible && yAxisVisible {
            let zeroText = Text("0")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(labelColor)
            context.draw(zeroText, at: CGPoint(x: tickX - 6, y: tickY + 11), anchor: .trailing)
        }
    }

    private func installScrollWheelZoomMonitor() {
        removeScrollWheelZoomMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let hover = hoverPoint,
                  canvasSize.width > 0,
                  canvasSize.height > 0,
                  abs(event.scrollingDeltaY) > 0.001 else {
                return event
            }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.006 : 0.08
            let delta = event.scrollingDeltaY * sensitivity
            let scaleFactor = min(1.45, max(0.65, exp(-delta)))
            let nx = min(max(Double(hover.x / canvasSize.width), 0.0), 1.0)
            let ny = min(max(Double(hover.y / canvasSize.height), 0.0), 1.0)
            let aspect = Double(canvasSize.height / canvasSize.width)
            grapherVM.zoom(scaleFactor: scaleFactor, anchorNormalizedX: nx, anchorNormalizedY: ny, aspect: aspect)
            return nil
        }
    }

    private func removeScrollWheelZoomMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func worldToScreen(
        x: Double,
        y: Double,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) -> CGPoint {
        let nx = (x - xRange.lowerBound) / max(1e-9, xRange.upperBound - xRange.lowerBound)
        let ny = (y - yRange.lowerBound) / max(1e-9, yRange.upperBound - yRange.lowerBound)
        return CGPoint(
            x: CGFloat(nx) * size.width,
            y: size.height - CGFloat(ny) * size.height
        )
    }

    private func niceGridStep(span: Double) -> Double {
        let raw = span / 10.0
        let exp = floor(log10(max(1e-6, raw)))
        let base = pow(10.0, exp)
        let frac = raw / base
        if frac < 1.5 { return base }
        if frac < 3.5 { return 2.0 * base }
        if frac < 7.5 { return 5.0 * base }
        return 10.0 * base
    }

    private func curveColor(for index: Int) -> Color {
        let palette: [Color] = [
            colorScheme == .dark
                ? Color(white: 0.90)
                : Color(white: 0.14),
            colorScheme == .dark
                ? Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)
                : Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255),
            colorScheme == .dark
                ? Color(red: 130 / 255, green: 158 / 255, blue: 184 / 255)
                : Color(red: 56 / 255, green: 86 / 255, blue: 118 / 255),
            colorScheme == .dark
                ? Color(white: 0.56)
                : Color(white: 0.44),
            colorScheme == .dark
                ? Color(red: 176 / 255, green: 190 / 255, blue: 204 / 255)
                : Color(red: 92 / 255, green: 110 / 255, blue: 128 / 255)
        ]
        return palette[abs(index) % palette.count]
    }
}

private struct EquationRow: View {
    @Binding var entry: EquationEntry
    let curveColor: Color
    let onDelete: () -> Void

    private var parseError: String? {
        do {
            _ = try MathExpressionEvaluator.compileEquation(entry.expression)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: LunarTokens.space2) {
                Button {
                    entry.isVisible.toggle()
                } label: {
                    Circle()
                        .fill(entry.isVisible ? curveColor : Color.secondary.opacity(0.25))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
                .help(entry.isVisible ? "Hide curve" : "Show curve")

                TextField("", text: $entry.expression)
                    .accessibilityLabel("Equation")
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if let error = parseError, !entry.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
    }
}

private struct CASHistoryRow: View {
    let entry: CASHistoryEntry
    let onPlot: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space1) {
            HStack(alignment: .firstTextBaseline, spacing: LunarTokens.space2) {
                Text("(%i\(entry.index))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                Text(entry.rawInput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Spacer()

                if let plottable = entry.plottableExpression {
                    Button("Plot") {
                        onPlot(plottable)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LunarTokens.accent(for: colorScheme))
                }
            }

            HStack(alignment: .center, spacing: LunarTokens.space2) {
                Text("(%o\(entry.index))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(entry.isError ? Color.secondary : LunarTokens.accent(for: colorScheme))
                    .frame(width: 48, alignment: .leading)

                if entry.isError {
                    Text(entry.outputLatex)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    MathView(
                        content: "$\(entry.outputLatex)$",
                        fontFamily: "serif",
                        fontSize: "sm",
                        compact: true,
                        minHeight: 22,
                        maxHeight: 72
                    )
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
    }
}
