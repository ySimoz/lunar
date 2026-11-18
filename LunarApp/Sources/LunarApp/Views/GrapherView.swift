import AppKit
import SwiftUI

/// Interactive `HSplitView` 2D math plotter with live parameter sliders,
/// root & intersection snapping, Marching Squares zero-contour rendering,
/// Graph-to-Card flashcard creation, and symbolic CAS console.
public struct GrapherView: View {
    @Bindable var grapherVM: GrapherViewModel
    var libraryVM: LibraryViewModel?

    @State private var hoverPoint: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var dragStartCenter: (x: Double, y: Double)?
    @State private var scrollMonitor: Any?
    @State private var activeCardDraft: GraphCardDraft?

    @Environment(\.colorScheme) private var colorScheme

    public init(grapherVM: GrapherViewModel, libraryVM: LibraryViewModel? = nil) {
        self.grapherVM = grapherVM
        self.libraryVM = libraryVM
    }

    public var body: some View {
        HSplitView {
            equationSidebar
                .frame(minWidth: 245, idealWidth: 280, maxWidth: 360)

            VStack(spacing: 0) {
                plotterPane
                    .frame(minHeight: 260, maxHeight: .infinity)

                Divider()

                casConsolePane
            }
            .frame(minWidth: 420)
        }
        .sheet(item: $activeCardDraft) { draft in
            if let decks = libraryVM?.decks, let firstDeck = decks.first {
                let initialDeck = activeTargetDeck(from: decks) ?? firstDeck
                CardEditorSheet(
                    deck: initialDeck,
                    availableDecks: decks,
                    initialCardType: draft.cardType,
                    initialFront: draft.front,
                    initialBack: draft.back,
                    initialExplanation: draft.explanation,
                    initialTags: draft.tags,
                    fontFamily: libraryVM?.preferences.fontFamily ?? "serif",
                    fontSize: libraryVM?.preferences.fontSize ?? "base"
                ) { createdCard in
                    Task {
                        _ = await libraryVM?.createCard(createdCard)
                    }
                }
            }
        }
    }

    private func activeTargetDeck(from decks: [Deck]) -> Deck? {
        if case .deck(let selectedId) = libraryVM?.selection {
            return decks.first { $0.id == selectedId }
        }
        return decks.first
    }

    // MARK: - Equation & Parameter Sidebar

    private var equationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Equations")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    grapherVM.addEmptyEquation()
                } label: {
                    Label("Add equation", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
            .padding(LunarTokens.space4)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: LunarTokens.space3) {
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
                    }

                    if !grapherVM.parameters.isEmpty {
                        parameterSection
                    }
                }
                .padding(LunarTokens.space3)
            }
        }
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
    }

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space2) {
            HStack {
                Text("Parameters")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, LunarTokens.space1)

            ForEach(grapherVM.parameters) { param in
                ParameterSliderRow(
                    parameter: param,
                    accentColor: LunarTokens.accent(for: colorScheme),
                    onValueChange: { newValue in
                        grapherVM.setParameterValue(name: param.name, value: newValue)
                    },
                    onBoundsChange: { minVal, maxVal, stepVal in
                        grapherVM.updateParameterBounds(
                            name: param.name,
                            min: minVal,
                            max: maxVal,
                            step: stepVal
                        )
                    },
                    onReset: {
                        grapherVM.resetParameter(name: param.name)
                    }
                )
            }
        }
    }

    // MARK: - 2D Canvas Plotter

    private var currentAspect: Double {
        canvasSize.width > 0 ? Double(canvasSize.height / canvasSize.width) : 0.7
    }

    private var canCreateCard: Bool {
        let hasVisibleEquation = grapherVM.equations.contains {
            $0.isVisible && !$0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasDecks = !(libraryVM?.decks.isEmpty ?? true)
        return hasVisibleEquation && hasDecks
    }

    private var createCardHelpText: String {
        if libraryVM?.decks.isEmpty ?? true {
            return "Create a deck first to save graph flashcards"
        }
        if !grapherVM.equations.contains(where: { $0.isVisible && !$0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Plot an equation to create a flashcard"
        }
        return "Create flashcard from current graph"
    }

    private var plotterPane: some View {
        let aspect = currentAspect
        let (xRange, yRange) = grapherVM.viewportRanges(aspect: aspect)
        let keyPoints = grapherVM.visibleKeyPoints(aspect: aspect)
        let hoveredWorld = hoverWorldCoordinates(xRange: xRange, yRange: yRange)
        let snappedHoverPoint = hoveredWorld.flatMap { world in
            grapherVM.nearestKeyPoint(
                toWorldX: world.x,
                worldY: world.y,
                aspect: aspect,
                from: keyPoints
            )
        }
        let pinnedPoint = keyPoints.first { $0.id == grapherVM.selectedKeyPointID }
        let highlightedPoint = snappedHoverPoint ?? pinnedPoint

        return ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                let size = proxy.size
                let paneAspect = size.width > 0 ? (size.height / size.width) : 0.7
                let paneRanges = grapherVM.viewportRanges(aspect: paneAspect)

                Canvas { context, canvas in
                    drawGridAndAxes(
                        in: &context,
                        size: canvas,
                        xRange: paneRanges.xRange,
                        yRange: paneRanges.yRange
                    )

                    drawPlottedCurves(
                        in: &context,
                        size: canvas,
                        xRange: paneRanges.xRange,
                        yRange: paneRanges.yRange
                    )

                    drawKeyPointMarkers(
                        in: &context,
                        size: canvas,
                        xRange: paneRanges.xRange,
                        yRange: paneRanges.yRange,
                        keyPoints: keyPoints,
                        highlightedPoint: highlightedPoint
                    )
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
                .onTapGesture(count: 1, coordinateSpace: .local) { location in
                    handleCanvasTap(
                        at: location,
                        size: size,
                        xRange: paneRanges.xRange,
                        yRange: paneRanges.yRange,
                        aspect: paneAspect,
                        keyPoints: keyPoints
                    )
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            if dragStartCenter == nil {
                                dragStartCenter = (grapherVM.centerX, grapherVM.centerY)
                            }
                            guard let start = dragStartCenter, size.width > 0, size.height > 0 else { return }
                            let halfHeight = grapherVM.halfWidth * paneAspect
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

            GrapherHUD(
                canCreateCard: canCreateCard,
                createCardHelpText: createCardHelpText,
                highlightedPoint: highlightedPoint,
                hoveredWorld: hoveredWorld,
                onZoomIn: {
                    grapherVM.zoom(scaleFactor: 0.75, aspect: currentAspect)
                },
                onZoomOut: {
                    grapherVM.zoom(scaleFactor: 1.0 / 0.75, aspect: currentAspect)
                },
                onReset: {
                    grapherVM.selectedKeyPointID = nil
                    grapherVM.resetViewport()
                },
                onCreateCard: {
                    openCardCreator(xRange: xRange, yRange: yRange, keyPoints: keyPoints)
                }
            )
            .padding(LunarTokens.space4)
        }
    }

    private func hoverWorldCoordinates(
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) -> (x: Double, y: Double)? {
        guard let hover = hoverPoint, canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let wx = xRange.lowerBound + (Double(hover.x) / Double(canvasSize.width)) * (xRange.upperBound - xRange.lowerBound)
        let wy = yRange.upperBound - (Double(hover.y) / Double(canvasSize.height)) * (yRange.upperBound - yRange.lowerBound)
        return (wx, wy)
    }

    private func handleCanvasTap(
        at location: CGPoint,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        aspect: Double,
        keyPoints: [GraphKeyPoint]
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let wx = xRange.lowerBound + (Double(location.x) / Double(size.width)) * (xRange.upperBound - xRange.lowerBound)
        let wy = yRange.upperBound - (Double(location.y) / Double(size.height)) * (yRange.upperBound - yRange.lowerBound)
        if let hit = grapherVM.nearestKeyPoint(
            toWorldX: wx,
            worldY: wy,
            aspect: aspect,
            from: keyPoints
        ) {
            grapherVM.selectedKeyPointID = (grapherVM.selectedKeyPointID == hit.id) ? nil : hit.id
        } else {
            grapherVM.selectedKeyPointID = nil
        }
    }

    private func openCardCreator(
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint]
    ) {
        guard let draft = GraphCardDraftBuilder.build(
            equations: grapherVM.equations,
            parameters: grapherVM.parameters,
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            isDark: colorScheme == .dark
        ) else {
            return
        }
        activeCardDraft = draft
    }

    private func drawPlottedCurves(
        in context: inout GraphicsContext,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) {
        let paramEnv = grapherVM.parameterEnvironment
        for entry in grapherVM.equations where entry.isVisible {
            guard let ast = try? MathExpressionEvaluator.compileEquation(entry.expression, allowFreeParameters: true) else {
                continue
            }
            let segments = MarchingSquares.extractSegments(
                ast: ast,
                xRange: xRange,
                yRange: yRange,
                parameters: paramEnv
            )
            var path = Path()
            for seg in segments {
                let p1 = worldToScreen(x: seg.x1, y: seg.y1, size: size, xRange: xRange, yRange: yRange)
                let p2 = worldToScreen(x: seg.x2, y: seg.y2, size: size, xRange: xRange, yRange: yRange)
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

    private func drawKeyPointMarkers(
        in context: inout GraphicsContext,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        highlightedPoint: GraphKeyPoint?
    ) {
        let canvasBg = colorScheme == .dark ? Color(white: 0.08) : Color(white: 0.97)
        let markerInk = LunarTokens.accent(for: colorScheme)

        // Draw intercepts first, intersections on top
        let ordered = keyPoints.sorted { $0.kind.snapPriority < $1.kind.snapPriority }
        for point in ordered {
            let screen = worldToScreen(x: point.x, y: point.y, size: size, xRange: xRange, yRange: yRange)
            guard screen.x >= -6, screen.x <= size.width + 6,
                  screen.y >= -6, screen.y <= size.height + 6 else {
                continue
            }

            let isActive = (point.id == highlightedPoint?.id)
            let radius: CGFloat = (point.kind == .intersection) ? 4.0 : 3.5
            let rect = CGRect(
                x: screen.x - radius,
                y: screen.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let circle = Path(ellipseIn: rect)

            if point.kind == .intersection {
                context.fill(circle, with: .color(markerInk.opacity(isActive ? 1.0 : 0.85)))
                context.stroke(circle, with: .color(canvasBg), lineWidth: 1.5)
            } else {
                context.fill(circle, with: .color(canvasBg))
                context.stroke(circle, with: .color(markerInk.opacity(isActive ? 1.0 : 0.72)), lineWidth: 1.5)
            }

            if isActive {
                let haloRadius = radius + 4.0
                let haloRect = CGRect(
                    x: screen.x - haloRadius,
                    y: screen.y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: haloRect),
                    with: .color(markerInk.opacity(0.65)),
                    lineWidth: 1.25
                )

                let coordLabel = Text(GraphFeatureSolver.formatPoint(x: point.x, y: point.y))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(markerInk)
                let labelY = max(14, screen.y - 14)
                let labelX = min(max(44, screen.x), size.width - 44)
                context.draw(coordLabel, at: CGPoint(x: labelX, y: labelY), anchor: .center)
            }
        }
    }

    // MARK: - Symbolic CAS Console

    private var casConsolePane: some View {
        VStack(spacing: 0) {
            if grapherVM.isConsoleExpanded && !grapherVM.casHistory.isEmpty {
                HStack(spacing: LunarTokens.space2) {
                    Text("Console")
                        .font(.system(size: 12, weight: .medium))
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
                    .help("Collapse console")
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
                    .accessibilityLabel("CAS input")
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

// MARK: - Plotter HUD

private struct GrapherHUD: View {
    let canCreateCard: Bool
    let createCardHelpText: String
    let highlightedPoint: GraphKeyPoint?
    let hoveredWorld: (x: Double, y: Double)?
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onReset: () -> Void
    let onCreateCard: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: LunarTokens.space2) {
            HStack(spacing: LunarTokens.space1) {
                Button(action: onZoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")

                Button(action: onZoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")

                Button("Reset", action: onReset)

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                Button(action: onCreateCard) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.badge.plus")
                            .font(.system(size: 11, weight: .medium))
                        Text("Create card")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .disabled(!canCreateCard)
                .help(createCardHelpText)
            }
            .buttonStyle(.bordered)
            .padding(LunarTokens.space2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
            }

            if let point = highlightedPoint {
                HStack(spacing: 6) {
                    Text(point.kind.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(GraphFeatureSolver.formatPoint(x: point.x, y: point.y))
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, LunarTokens.space2)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                }
            } else if let world = hoveredWorld {
                Text(String(format: "(%.2f, %.2f)", world.x, world.y))
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
    }
}

// MARK: - Parameter Slider Row

private struct ParameterSliderRow: View {
    let parameter: GraphParameter
    let accentColor: Color
    let onValueChange: (Double) -> Void
    let onBoundsChange: (Double, Double, Double) -> Void
    let onReset: () -> Void

    @State private var isEditingBounds = false
    @State private var minText: String = ""
    @State private var maxText: String = ""
    @State private var stepText: String = ""

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { parameter.value },
            set: { onValueChange($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space2) {
            HStack(spacing: LunarTokens.space2) {
                Text("\(String(parameter.name)) =")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)

                Text(GraphFeatureSolver.formatCoordinate(parameter.value))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    if !isEditingBounds {
                        minText = GraphFeatureSolver.formatCoordinate(parameter.min)
                        maxText = GraphFeatureSolver.formatCoordinate(parameter.max)
                        stepText = GraphFeatureSolver.formatCoordinate(parameter.step)
                    }
                    isEditingBounds.toggle()
                } label: {
                    Text("\(GraphFeatureSolver.formatCoordinate(parameter.min))…\(GraphFeatureSolver.formatCoordinate(parameter.max))")
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Edit parameter bounds")

                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Reset parameter")
            }

            Slider(
                value: sliderBinding,
                in: parameter.validatedRange,
                step: parameter.validatedStep
            )
            .controlSize(.small)
            .tint(accentColor)

            if isEditingBounds {
                boundsEditorRow
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
    }

    private var boundsEditorRow: some View {
        HStack(spacing: LunarTokens.space2) {
            boundField(label: "Min", text: $minText)
            boundField(label: "Max", text: $maxText)
            boundField(label: "Step", text: $stepText)

            Button("Apply") {
                commitBounds()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.top, 2)
    }

    private func boundField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    commitBounds()
                }
        }
    }

    private func commitBounds() {
        let minVal = Double(minText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? parameter.min
        let maxVal = Double(maxText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? parameter.max
        let stepVal = Double(stepText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? parameter.step
        onBoundsChange(minVal, maxVal, stepVal)
        isEditingBounds = false
    }
}

// MARK: - Equation & CAS Rows

private struct EquationRow: View {
    @Binding var entry: EquationEntry
    let curveColor: Color
    let onDelete: () -> Void

    private var parseError: String? {
        do {
            _ = try MathExpressionEvaluator.compileEquation(entry.expression, allowFreeParameters: true)
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
