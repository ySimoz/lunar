import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Interactive `HSplitView` 2D math plotter with live parameter sliders,
/// root & intersection snapping, region selection, PNG/JPEG export, and symbolic CAS console.
public struct GrapherView: View {
    @Bindable var grapherVM: GrapherViewModel

    @State private var hoverPoint: CGPoint?
    @State private var canvasSize: CGSize = .zero
    @State private var dragStartCenter: (x: Double, y: Double)?
    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var didCopyGraphImage = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var isSelectingRegion = false
    @State private var cropRectInCanvas: CGRect?
    @State private var cropDragOrigin: CGPoint?
    @State private var showFunctionPalette = false
    @State private var activeEquationID: UUID?
    @State private var editorRegistry = EquationEditorRegistry()
    @State private var paletteHitTargets = PaletteHitTargets()

    private var isSelectionModeActive: Bool {
        isSelectingRegion || cropRectInCanvas != nil
    }

    @Environment(\.colorScheme) private var colorScheme

    public init(grapherVM: GrapherViewModel) {
        self.grapherVM = grapherVM
    }

    public var body: some View {
        HSplitView {
            equationSidebar
                .frame(minWidth: 245, idealWidth: 280, maxWidth: 360)
                .disabled(isSelectionModeActive)
                .opacity(isSelectionModeActive ? 0.45 : 1.0)

            VStack(spacing: 0) {
                plotterPane
                    .frame(minHeight: 260, maxHeight: .infinity)

                Divider()

                casConsolePane
                    .disabled(isSelectionModeActive)
                    .opacity(isSelectionModeActive ? 0.45 : 1.0)
            }
            .frame(minWidth: 420)
        }
    }

    // MARK: - Equation & Parameter Sidebar

    private var equationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: LunarTokens.space2) {
                Text("Equations")
                    .font(.system(size: 13, weight: .medium))
                Spacer()

                Button {
                    grapherVM.addEmptyEquation()
                    activeEquationID = grapherVM.equations.last?.id
                } label: {
                    Label("Add", systemImage: "plus")
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
                                    editorRegistry: editorRegistry,
                                    onFocus: {
                                        activeEquationID = entry.id
                                    },
                                    onDelete: {
                                        if activeEquationID == entry.id {
                                            activeEquationID = nil
                                        }
                                        editorRegistry.unregister(id: entry.id)
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

    private var hasVisibleEquation: Bool {
        grapherVM.equations.contains {
            $0.isVisible && !$0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                    guard !isSelectionModeActive else { return }
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
                            guard size.width > 0, size.height > 0 else { return }
                            if isSelectionModeActive {
                                if cropDragOrigin == nil {
                                    cropDragOrigin = value.startLocation
                                }
                                if let origin = cropDragOrigin {
                                    cropRectInCanvas = normalizedCropRect(
                                        from: origin,
                                        to: value.location,
                                        in: size
                                    )
                                }
                                return
                            }

                            if dragStartCenter == nil {
                                dragStartCenter = (grapherVM.centerX, grapherVM.centerY)
                            }
                            guard let start = dragStartCenter else { return }
                            let halfHeight = grapherVM.halfWidth * paneAspect
                            let worldPerPixelX = (2.0 * grapherVM.halfWidth) / Double(size.width)
                            let worldPerPixelY = (2.0 * halfHeight) / Double(size.height)
                            grapherVM.centerX = start.x - Double(value.translation.width) * worldPerPixelX
                            grapherVM.centerY = start.y + Double(value.translation.height) * worldPerPixelY
                        }
                        .onEnded { _ in
                            if isSelectionModeActive {
                                cropDragOrigin = nil
                                if let rect = cropRectInCanvas, (rect.width < 12 || rect.height < 12) {
                                    cropRectInCanvas = nil
                                } else if cropRectInCanvas != nil {
                                    isSelectingRegion = false
                                }
                            }
                            dragStartCenter = nil
                        }
                )
                .overlay {
                    if let crop = cropRectInCanvas {
                        CropSelectionOverlay(cropRect: crop, accentColor: LunarTokens.accent(for: colorScheme))
                            .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    installScrollWheelZoomMonitor()
                }
                .onDisappear {
                    removeScrollWheelZoomMonitor()
                }
            }

            GrapherHUD(
                canCopyImage: hasVisibleEquation,
                didCopyImage: didCopyGraphImage,
                isSelectingRegion: isSelectingRegion,
                hasCropSelection: cropRectInCanvas != nil,
                isFunctionPaletteOpen: showFunctionPalette && !isSelectionModeActive,
                highlightedPoint: isSelectionModeActive ? nil : highlightedPoint,
                hoveredWorld: isSelectionModeActive ? nil : hoveredWorld,
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
                onToggleFunctionPalette: {
                    showFunctionPalette.toggle()
                },
                onToggleSelectRegion: {
                    if isSelectionModeActive {
                        clearRegionSelection()
                    } else {
                        isSelectingRegion = true
                    }
                },
                onClearCrop: {
                    clearRegionSelection()
                },
                onCopyImage: {
                    copyGraphImage(xRange: xRange, yRange: yRange, keyPoints: keyPoints)
                },
                onExportImage: { format in
                    exportGraphImage(format: format, xRange: xRange, yRange: yRange, keyPoints: keyPoints)
                },
                onAttachPaletteButton: { view in
                    paletteHitTargets.buttonView = view
                },
                onAttachPalettePanel: { view in
                    paletteHitTargets.panelView = view
                },
                onInsertSnippet: { snippet in
                    insertSnippetIntoActiveEquation(snippet)
                }
            )
            .padding(LunarTokens.space4)
        }
        .onChange(of: showFunctionPalette) { _, isOpen in
            if isOpen {
                installPaletteOutsideClickMonitor()
            } else {
                paletteHitTargets.removeMonitor()
            }
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

    private func normalizedCropRect(from a: CGPoint, to b: CGPoint, in bounds: CGSize) -> CGRect {
        let minX = max(0, min(bounds.width, min(a.x, b.x)))
        let maxX = max(0, min(bounds.width, max(a.x, b.x)))
        let minY = max(0, min(bounds.height, min(a.y, b.y)))
        let maxY = max(0, min(bounds.height, max(a.y, b.y)))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func resolvedCaptureTarget(
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint],
        longestEdge: Int
    ) -> (viewport: GraphSnapshotRenderer.ExportViewport, points: [GraphKeyPoint], visibleEquations: [EquationEntry]) {
        let viewport = GraphSnapshotRenderer.resolveExportViewport(
            cropRect: cropRectInCanvas,
            canvasSize: canvasSize,
            xRange: xRange,
            yRange: yRange,
            longestEdge: longestEdge
        )
        let filteredPoints = keyPoints.filter {
            viewport.xRange.contains($0.x) && viewport.yRange.contains($0.y)
        }
        let visibleEquations = grapherVM.equations.filter {
            $0.isVisible && !$0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return (viewport, filteredPoints, visibleEquations)
    }

    private func copyGraphImage(
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint]
    ) {
        let target = resolvedCaptureTarget(
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            longestEdge: 640
        )
        guard let payload = GraphSnapshotRenderer.renderPNG(
            equations: grapherVM.equations,
            parameters: grapherVM.parameterEnvironment,
            xRange: target.viewport.xRange,
            yRange: target.viewport.yRange,
            keyPoints: target.points,
            isDark: colorScheme == .dark,
            width: target.viewport.width,
            height: target.viewport.height
        ) else {
            return
        }

        let label = GraphSnapshotRenderer.defaultLabel(for: target.visibleEquations)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(payload.pngData, forType: .png)
        if let tiff = NSImage(data: payload.pngData)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(label, forType: CardAttachmentCodec.lunarLabelPasteboardType)
        pasteboard.writeObjects([item])

        didCopyGraphImage = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            didCopyGraphImage = false
        }
    }

    private func exportGraphImage(
        format: GraphImageFormat,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        keyPoints: [GraphKeyPoint]
    ) {
        let target = resolvedCaptureTarget(
            xRange: xRange,
            yRange: yRange,
            keyPoints: keyPoints,
            longestEdge: 1120
        )
        guard let data = GraphSnapshotRenderer.renderImageData(
            equations: grapherVM.equations,
            parameters: grapherVM.parameterEnvironment,
            xRange: target.viewport.xRange,
            yRange: target.viewport.yRange,
            keyPoints: target.points,
            format: format,
            isDark: colorScheme == .dark,
            width: target.viewport.width,
            height: target.viewport.height
        ) else {
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = "lunar-graph.\(format.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func insertSnippetIntoActiveEquation(_ snippet: GraphPaletteSnippet) {
        if grapherVM.equations.isEmpty {
            grapherVM.addEmptyEquation()
            guard let newID = grapherVM.equations.last?.id else { return }
            let initialText = snippet.emptyRowText ?? snippet.text
            grapherVM.equations[grapherVM.equations.count - 1].expression = initialText
            activeEquationID = newID
            editorRegistry.pendingInitialFocus = (id: newID, cursorBackOffset: snippet.cursorBackOffset)
            return
        }

        let targetIndex: Int = if let activeID = activeEquationID,
                                  let idx = grapherVM.equations.firstIndex(where: { $0.id == activeID }) {
            idx
        } else {
            grapherVM.equations.count - 1
        }
        let targetID = grapherVM.equations[targetIndex].id
        activeEquationID = targetID
        if !editorRegistry.insert(snippet, into: targetID) {
            let current = grapherVM.equations[targetIndex].expression
            let insertion = current.isEmpty ? (snippet.emptyRowText ?? snippet.text) : snippet.text
            grapherVM.equations[targetIndex].expression = current + insertion
            editorRegistry.pendingInitialFocus = (id: targetID, cursorBackOffset: snippet.cursorBackOffset)
        }
    }

    private func drawPlottedCurves(
        in context: inout GraphicsContext,
        size: CGSize,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) {
        let paramEnv = grapherVM.parameterEnvironment
        for entry in grapherVM.equations where entry.isVisible {
            guard let compiled = try? MathExpressionEvaluator.compileGraphEquation(entry.expression, allowFreeParameters: true) else {
                continue
            }
            let color = curveColor(for: entry.colorIndex)

            if compiled.isInequality {
                let rects = MarchingSquares.extractShadedRects(
                    compiled: compiled,
                    xRange: xRange,
                    yRange: yRange,
                    parameters: paramEnv
                )
                for r in rects {
                    let p1 = worldToScreen(x: r.xMin, y: r.yMin, size: size, xRange: xRange, yRange: yRange)
                    let p2 = worldToScreen(x: r.xMax, y: r.yMax, size: size, xRange: xRange, yRange: yRange)
                    let screenRect = CGRect(
                        x: min(p1.x, p2.x),
                        y: min(p1.y, p2.y),
                        width: abs(p2.x - p1.x),
                        height: abs(p2.y - p1.y)
                    )
                    context.fill(Path(screenRect), with: .color(color.opacity(0.18)))
                }
            }

            let strokeStyle = compiled.hasStrictBoundary
                ? StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round, dash: [5, 4])
                : StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)

            for boundaryAST in compiled.boundaries {
                let segments = MarchingSquares.extractSegments(
                    ast: boundaryAST,
                    xRange: xRange,
                    yRange: yRange,
                    parameters: paramEnv,
                    restrictions: compiled.restrictions
                )
                var path = Path()
                for seg in segments {
                    let p1 = worldToScreen(x: seg.x1, y: seg.y1, size: size, xRange: xRange, yRange: yRange)
                    let p2 = worldToScreen(x: seg.x2, y: seg.y2, size: size, xRange: xRange, yRange: yRange)
                    path.move(to: p1)
                    path.addLine(to: p2)
                }
                context.stroke(path, with: .color(color), style: strokeStyle)
            }
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

    private func clearRegionSelection() {
        cropRectInCanvas = nil
        cropDragOrigin = nil
        isSelectingRegion = false
    }

    private func installScrollWheelZoomMonitor() {
        removeScrollWheelZoomMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !isSelectionModeActive,
                  let hover = hoverPoint,
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

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc (keyCode 53) closes function palette or cancels/deselects region selection.
            guard event.keyCode == 53 else { return event }
            if showFunctionPalette {
                showFunctionPalette = false
                return nil
            }
            if isSelectionModeActive {
                clearRegionSelection()
                return nil
            }
            return event
        }
    }

    private func installPaletteOutsideClickMonitor() {
        paletteHitTargets.removeMonitor()
        paletteHitTargets.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard showFunctionPalette else { return event }
            let targetWindow = paletteHitTargets.panelView?.window ?? paletteHitTargets.buttonView?.window
            if let targetWindow, event.window !== targetWindow {
                showFunctionPalette = false
                return event
            }
            let inPanel = paletteHitTargets.panelView.map { view in
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            } ?? false
            let inButton = paletteHitTargets.buttonView.map { view in
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            } ?? false
            if !inPanel && !inButton {
                showFunctionPalette = false
            }
            return event
        }
    }

    private func removeScrollWheelZoomMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        paletteHitTargets.removeMonitor()
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

private struct CropSelectionOverlay: View {
    let cropRect: CGRect
    let accentColor: Color

    var body: some View {
        GeometryReader { proxy in
            let fullRect = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                Path { path in
                    path.addRect(fullRect)
                    path.addRect(cropRect)
                }
                .fill(Color.black.opacity(0.24), style: FillStyle(eoFill: true))

                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(accentColor, lineWidth: 1.5)
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
            }
        }
    }
}

private struct GrapherHUD: View {
    let canCopyImage: Bool
    let didCopyImage: Bool
    let isSelectingRegion: Bool
    let hasCropSelection: Bool
    let isFunctionPaletteOpen: Bool
    let highlightedPoint: GraphKeyPoint?
    let hoveredWorld: (x: Double, y: Double)?
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onReset: () -> Void
    let onToggleFunctionPalette: () -> Void
    let onToggleSelectRegion: () -> Void
    let onClearCrop: () -> Void
    let onCopyImage: () -> Void
    let onExportImage: (GraphImageFormat) -> Void
    let onAttachPaletteButton: (NSView) -> Void
    let onAttachPalettePanel: (NSView) -> Void
    let onInsertSnippet: (GraphPaletteSnippet) -> Void

    private var isSelectionLocked: Bool {
        isSelectingRegion || hasCropSelection
    }

    private var canRunCaptureAction: Bool {
        guard canCopyImage else { return false }
        if isSelectionLocked {
            return hasCropSelection
        }
        return true
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: LunarTokens.space2) {
            HStack(spacing: LunarTokens.space1) {
                Button(action: onZoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .disabled(isSelectionLocked)
                .opacity(isSelectionLocked ? 0.4 : 1.0)
                .help("Zoom in")

                Button(action: onZoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .disabled(isSelectionLocked)
                .opacity(isSelectionLocked ? 0.4 : 1.0)
                .help("Zoom out")

                Button("Reset", action: onReset)
                    .disabled(isSelectionLocked)
                    .opacity(isSelectionLocked ? 0.4 : 1.0)

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                Button(action: onToggleSelectRegion) {
                    HStack(spacing: 4) {
                        Image(systemName: isSelectionLocked ? "xmark" : "crop")
                            .font(.system(size: 11, weight: .medium))
                        Text(isSelectionLocked ? "Deselect" : "Select")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(isSelectionLocked ? .primary : .secondary)
                }
                .disabled(!canCopyImage && !isSelectionLocked)
                .help(isSelectionLocked ? "Cancel region selection (Esc)" : "Drag on canvas to select an export region")

                Button(action: onCopyImage) {
                    HStack(spacing: 4) {
                        Image(systemName: didCopyImage ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 11, weight: .medium))
                        Text(didCopyImage ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .disabled(!canRunCaptureAction)
                .opacity((isSelectionLocked && !hasCropSelection) ? 0.4 : 1.0)
                .help(hasCropSelection ? "Copy selected region as PNG" : "Copy visible graph as PNG")

                Menu {
                    Button("Save as PNG…") {
                        onExportImage(.png)
                    }
                    Button("Save as JPEG…") {
                        onExportImage(.jpeg)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .medium))
                        Text("Export")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canRunCaptureAction)
                .opacity((isSelectionLocked && !hasCropSelection) ? 0.4 : 1.0)
                .help(hasCropSelection ? "Save selected region as PNG or JPEG" : "Save graph as PNG or JPEG")

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                Button(action: onToggleFunctionPalette) {
                    Image(systemName: "function")
                        .font(.system(size: 12, weight: .medium))
                }
                .disabled(isSelectionLocked)
                .opacity(isSelectionLocked ? 0.4 : 1.0)
                .background(PaletteAnchorView(onAttach: onAttachPaletteButton))
                .help("Insert constants, functions & inequalities")
            }
            .buttonStyle(.bordered)
            .padding(LunarTokens.space2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
            }

            if isFunctionPaletteOpen {
                GrapherFunctionPalettePanel(onInsert: onInsertSnippet)
                    .background(PaletteAnchorView(onAttach: onAttachPalettePanel))
            }

            if isSelectionLocked {
                HStack(spacing: 6) {
                    Text(hasCropSelection ? "Region selected — Copy or Export (Esc to deselect)" : "Drag to select region · Esc to cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)

                    Button(action: onClearCrop) {
                        Text("Esc")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                    .buttonStyle(.borderless)
                    .help("Deselect region (Esc)")
                }
                .padding(.horizontal, LunarTokens.space2)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                }
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
                Text("\(String(parameter.name)) = \(GraphFeatureSolver.formatCoordinate(parameter.value))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)

                Spacer()

                Menu {
                    Button("Natural (0, 1, 2…)") {
                        onBoundsChange(0, max(10, parameter.max), 1)
                    }
                    Button("Integers (…, -1, 0, 1, …)") {
                        onBoundsChange(-10, 10, 1)
                    }
                    Button("Step 2 (0, 2, 4…)") {
                        onBoundsChange(0, 20, 2)
                    }

                    Divider()

                    Menu("Step") {
                        ForEach([0.05, 0.1, 0.5, 1.0, 2.0], id: \.self) { step in
                            Button(GraphFeatureSolver.formatCoordinate(step)) {
                                onBoundsChange(parameter.min, parameter.max, step)
                            }
                        }
                    }

                    Menu("Range") {
                        Button("−10 … 10") { onBoundsChange(-10, 10, parameter.step) }
                        Button("−5 … 5") { onBoundsChange(-5, 5, parameter.step) }
                        Button("0 … 10") { onBoundsChange(0, 10, parameter.step) }
                        Button("0 … 20") { onBoundsChange(0, 20, parameter.step) }
                        Button("0 … 1") { onBoundsChange(0, 1, min(parameter.step, 0.1)) }
                    }

                    Divider()

                    Button("Edit range & step…") {
                        minText = GraphFeatureSolver.formatCoordinate(parameter.min)
                        maxText = GraphFeatureSolver.formatCoordinate(parameter.max)
                        stepText = GraphFeatureSolver.formatCoordinate(parameter.step)
                        isEditingBounds = true
                    }

                    Button("Reset", action: onReset)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Slider(
                value: sliderBinding,
                in: parameter.validatedRange,
                step: parameter.validatedStep
            )
            .controlSize(.small)
            .tint(accentColor)

            if isEditingBounds {
                VStack(alignment: .leading, spacing: LunarTokens.space2) {
                    HStack(spacing: LunarTokens.space2) {
                        boundField(label: "Min", text: $minText)
                        boundField(label: "Max", text: $maxText)
                        boundField(label: "Step", text: $stepText)
                    }
                    HStack(spacing: LunarTokens.space2) {
                        Spacer()
                        Button("Cancel") {
                            isEditingBounds = false
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))

                        Button("Apply") {
                            commitBounds()
                        }
                        .buttonStyle(MonochromeProminentButtonStyle(compact: true))
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
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

private struct GraphPaletteSnippet: Identifiable, Equatable {
    let label: String
    let text: String
    let cursorBackOffset: Int
    let emptyRowText: String?

    init(
        _ label: String,
        _ text: String,
        cursorBackOffset: Int = 0,
        emptyRowText: String? = nil
    ) {
        self.label = label
        self.text = text
        self.cursorBackOffset = cursorBackOffset
        self.emptyRowText = emptyRowText
    }

    var id: String { label + text }
}

@MainActor
private final class EquationEditorRegistry {
    struct Entry {
        weak var textView: EquationNSTextView?
        var commitExpression: (String) -> Void
    }

    private var entries: [UUID: Entry] = [:]
    var pendingInitialFocus: (id: UUID, cursorBackOffset: Int)?

    func register(id: UUID, textView: EquationNSTextView, commitExpression: @escaping (String) -> Void) {
        entries[id] = Entry(textView: textView, commitExpression: commitExpression)
    }

    func unregister(id: UUID) {
        entries.removeValue(forKey: id)
        if pendingInitialFocus?.id == id {
            pendingInitialFocus = nil
        }
    }

    func insert(_ snippet: GraphPaletteSnippet, into equationID: UUID) -> Bool {
        guard let entry = entries[equationID], let textView = entry.textView else {
            return false
        }
        textView.window?.makeFirstResponder(textView)
        let current = textView.string as NSString
        let insertionText = (current.length == 0 ? (snippet.emptyRowText ?? snippet.text) : snippet.text)
        let selected = textView.selectedRange()
        let safeLoc = min(max(0, selected.location), current.length)
        let safeRange = NSRange(location: safeLoc, length: min(selected.length, current.length - safeLoc))

        guard textView.shouldChangeText(in: safeRange, replacementString: insertionText) else {
            return false
        }
        textView.textStorage?.replaceCharacters(in: safeRange, with: insertionText)
        let insertedNSLen = (insertionText as NSString).length
        let caretLoc = max(0, safeRange.location + insertedNSLen - snippet.cursorBackOffset)
        EquationInputField.applyScriptStyling(to: textView)
        textView.setSelectedRange(NSRange(location: caretLoc, length: 0))
        EquationInputField.syncTypingAttributes(for: textView)
        let updated = textView.string
        textView.didChangeText()
        entry.commitExpression(updated)
        return true
    }
}

private struct GrapherFunctionPalettePanel: View {
    let onInsert: (GraphPaletteSnippet) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let groups: [(title: String, items: [GraphPaletteSnippet])] = [
        ("Constants", [
            GraphPaletteSnippet("π", "pi"),
            GraphPaletteSnippet("e", "e"),
            GraphPaletteSnippet("φ", "phi")
        ]),
        ("Inequalities & Domain", [
            GraphPaletteSnippet("=", " = "),
            GraphPaletteSnippet("≤", " <= "),
            GraphPaletteSnippet("≥", " >= "),
            GraphPaletteSnippet("<", " < "),
            GraphPaletteSnippet(">", " > "),
            GraphPaletteSnippet("{x > 0}", " {x > 0}"),
            GraphPaletteSnippet("{a ≤ x ≤ b}", " {-2 <= x <= 2}")
        ]),
        ("Powers & Roots", [
            GraphPaletteSnippet("x²", "^2", emptyRowText: "x^2"),
            GraphPaletteSnippet("x³", "^3", emptyRowText: "x^3"),
            GraphPaletteSnippet("xⁿ", "^()", cursorBackOffset: 1, emptyRowText: "x^()"),
            GraphPaletteSnippet("√", "sqrt()", cursorBackOffset: 1),
            GraphPaletteSnippet("ⁿ√", "^(1/)", cursorBackOffset: 1, emptyRowText: "x^(1/)"),
            GraphPaletteSnippet("|x|", "||", cursorBackOffset: 1)
        ]),
        ("Logarithms & Exp", [
            GraphPaletteSnippet("ln", "ln()", cursorBackOffset: 1),
            GraphPaletteSnippet("log₁₀", "log()", cursorBackOffset: 1),
            GraphPaletteSnippet("logₐ(x)", "log_()", cursorBackOffset: 2),
            GraphPaletteSnippet("eˣ", "e^()", cursorBackOffset: 1)
        ]),
        ("Trig & Hyperbolic", [
            GraphPaletteSnippet("sin", "sin()", cursorBackOffset: 1),
            GraphPaletteSnippet("cos", "cos()", cursorBackOffset: 1),
            GraphPaletteSnippet("tan", "tan()", cursorBackOffset: 1),
            GraphPaletteSnippet("csc", "csc()", cursorBackOffset: 1),
            GraphPaletteSnippet("sec", "sec()", cursorBackOffset: 1),
            GraphPaletteSnippet("cot", "cot()", cursorBackOffset: 1),
            GraphPaletteSnippet("asin", "asin()", cursorBackOffset: 1),
            GraphPaletteSnippet("acos", "acos()", cursorBackOffset: 1),
            GraphPaletteSnippet("atan", "atan()", cursorBackOffset: 1),
            GraphPaletteSnippet("sinh", "sinh()", cursorBackOffset: 1),
            GraphPaletteSnippet("cosh", "cosh()", cursorBackOffset: 1),
            GraphPaletteSnippet("tanh", "tanh()", cursorBackOffset: 1)
        ]),
        ("Bounds & Rounding", [
            GraphPaletteSnippet("abs", "abs()", cursorBackOffset: 1),
            GraphPaletteSnippet("min", "min(, )", cursorBackOffset: 3),
            GraphPaletteSnippet("max", "max(, )", cursorBackOffset: 3),
            GraphPaletteSnippet("mod", "mod(, )", cursorBackOffset: 3),
            GraphPaletteSnippet("floor", "floor()", cursorBackOffset: 1),
            GraphPaletteSnippet("ceil", "ceil()", cursorBackOffset: 1),
            GraphPaletteSnippet("round", "round()", cursorBackOffset: 1)
        ])
    ]

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 5)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LunarTokens.cardRadius, style: .continuous)
        let fill = colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.98)

        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                        ForEach(group.items) { item in
                            Button {
                                onInsert(item)
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(
                                        Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(LunarTokens.space3)
        .frame(width: 312, alignment: .leading)
        .background(fill, in: shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct EquationRow: View {
    @Binding var entry: EquationEntry
    let curveColor: Color
    let editorRegistry: EquationEditorRegistry
    let onFocus: () -> Void
    let onDelete: () -> Void

    @State private var draftExpression: String = ""
    @State private var lastCommittedExpression: String = ""
    @State private var debounceTask: Task<Void, Never>?

    private var parseError: String? {
        do {
            _ = try MathExpressionEvaluator.compileGraphEquation(entry.expression, allowFreeParameters: true)
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

                ZStack(alignment: .leading) {
                    if draftExpression.isEmpty {
                        Text("e.g. y <= x + 2")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.65))
                            .allowsHitTesting(false)
                    }

                    EquationInputField(
                        equationID: entry.id,
                        text: $draftExpression,
                        editorRegistry: editorRegistry,
                        onCommitImmediate: { committed in
                            debounceTask?.cancel()
                            lastCommittedExpression = committed
                            draftExpression = committed
                            if entry.expression != committed {
                                entry.expression = committed
                            }
                        },
                        onFocusChange: { focused in
                            if focused {
                                onFocus()
                            } else {
                                commitImmediately()
                            }
                        },
                        onSubmit: {
                            commitImmediately()
                        }
                    )
                    .frame(height: 20)
                }

                Button(action: {
                    debounceTask?.cancel()
                    onDelete()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if let error = parseError,
               draftExpression == entry.expression,
               !entry.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
        .onAppear {
            if draftExpression != entry.expression {
                draftExpression = entry.expression
                lastCommittedExpression = entry.expression
            }
        }
        .onChange(of: entry.expression) { _, newValue in
            if newValue != lastCommittedExpression {
                lastCommittedExpression = newValue
                draftExpression = newValue
            }
        }
        .onChange(of: draftExpression) { _, newValue in
            scheduleCommit(newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
        }
    }

    private func scheduleCommit(_ text: String) {
        debounceTask?.cancel()
        guard text != entry.expression else { return }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled else { return }
            if entry.expression != text {
                lastCommittedExpression = text
                entry.expression = text
            }
        }
    }

    private func commitImmediately() {
        debounceTask?.cancel()
        if entry.expression != draftExpression {
            lastCommittedExpression = draftExpression
            entry.expression = draftExpression
        }
    }
}

/// Single-line equation editor supporting visual `^` superscript and `_` subscript formatting
/// plus direct cursor-accurate palette insertion via `EquationEditorRegistry`.
private struct EquationInputField: NSViewRepresentable {
    let equationID: UUID
    @Binding var text: String
    let editorRegistry: EquationEditorRegistry
    let onCommitImmediate: (String) -> Void
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    private static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let scriptFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChange: onFocusChange, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = EquationNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = context.coordinator.onSubmit
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.baseFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 100_000, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.string = text
        Self.applyScriptStyling(to: textView)

        editorRegistry.register(id: equationID, textView: textView, commitExpression: onCommitImmediate)
        if let pendingFocus = editorRegistry.pendingInitialFocus, pendingFocus.id == equationID {
            editorRegistry.pendingInitialFocus = nil
            let backOffset = pendingFocus.cursorBackOffset
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                let nsLen = (textView.string as NSString).length
                let caret = max(0, nsLen - backOffset)
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                Self.syncTypingAttributes(for: textView)
            }
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onSubmit = onSubmit

        guard let textView = scrollView.documentView as? EquationNSTextView else { return }
        textView.onSubmit = onSubmit
        editorRegistry.register(id: equationID, textView: textView, commitExpression: onCommitImmediate)

        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            Self.applyScriptStyling(to: textView)
            let clampedLoc = min(sel.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
            Self.syncTypingAttributes(for: textView)
        }
    }

    /// Styles `^` superscripts (`+4.5pt`) and `_` subscripts (`-3.5pt`) with a smaller font.
    static func applyScriptStyling(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: 0
        ], range: fullRange)

        let ranges = scriptRanges(in: storage.string)
        for markerRange in ranges.markers {
            let clamped = NSIntersectionRange(markerRange, fullRange)
            if clamped.length > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: clamped)
            }
        }
        for supRange in ranges.supBodies {
            let clamped = NSIntersectionRange(supRange, fullRange)
            if clamped.length > 0 {
                storage.addAttributes([
                    .font: scriptFont,
                    .baselineOffset: 4.5,
                    .foregroundColor: NSColor.labelColor
                ], range: clamped)
            }
        }
        for subRange in ranges.subBodies {
            let clamped = NSIntersectionRange(subRange, fullRange)
            if clamped.length > 0 {
                storage.addAttributes([
                    .font: scriptFont,
                    .baselineOffset: -3.5,
                    .foregroundColor: NSColor.labelColor
                ], range: clamped)
            }
        }
        storage.endEditing()
    }

    static func syncTypingAttributes(for textView: NSTextView) {
        let caret = textView.selectedRange().location
        let ranges = scriptRanges(in: textView.string)
        let inSup = ranges.supMarkers.contains { $0.location + $0.length == caret }
            || ranges.supBodies.contains { caret > $0.location && caret <= $0.location + $0.length }
        let inSub = ranges.subMarkers.contains { $0.location + $0.length == caret }
            || ranges.subBodies.contains { caret > $0.location && caret <= $0.location + $0.length }

        if inSup {
            textView.typingAttributes = [
                .font: scriptFont,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: 4.5
            ]
        } else if inSub {
            textView.typingAttributes = [
                .font: scriptFont,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: -3.5
            ]
        } else {
            textView.typingAttributes = [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: 0
            ]
        }
    }

    private struct ScriptRanges {
        var supMarkers: [NSRange] = []
        var subMarkers: [NSRange] = []
        var supBodies: [NSRange] = []
        var subBodies: [NSRange] = []

        var markers: [NSRange] { supMarkers + subMarkers }
    }

    private static func scriptRanges(in string: String) -> ScriptRanges {
        let chars = Array(string)
        var utf16Starts: [Int] = []
        utf16Starts.reserveCapacity(chars.count + 1)
        var offset = 0
        for ch in chars {
            utf16Starts.append(offset)
            offset += ch.utf16.count
        }
        utf16Starts.append(offset)

        func makeNSRange(_ startIdx: Int, _ endIdx: Int) -> NSRange {
            NSRange(location: utf16Starts[startIdx], length: utf16Starts[endIdx] - utf16Starts[startIdx])
        }

        var result = ScriptRanges()
        var i = 0
        while i < chars.count {
            let marker = chars[i]
            guard marker == "^" || marker == "_" else {
                i += 1
                continue
            }
            let markerRange = makeNSRange(i, i + 1)
            if marker == "^" {
                result.supMarkers.append(markerRange)
            } else {
                result.subMarkers.append(markerRange)
            }

            var j = i + 1
            guard j < chars.count else { break }

            if chars[j] == "(" {
                let start = j
                var depth = 0
                while j < chars.count {
                    if chars[j] == "(" { depth += 1 }
                    else if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 {
                            j += 1
                            break
                        }
                    }
                    j += 1
                }
                if marker == "^" {
                    result.supBodies.append(makeNSRange(start, j))
                } else if j < chars.count && chars[j] == "(" {
                    // For `log_(base)(arg)`, style `(base)` as subscript while keeping `(arg)` normal size.
                    result.subBodies.append(makeNSRange(start, j))
                }
                i = j
            } else {
                let start = j
                if chars[j] == "-" { j += 1 }
                while j < chars.count && (chars[j].isLetter || chars[j].isNumber || chars[j] == ".") {
                    j += 1
                }
                if j > start {
                    let bodyRange = makeNSRange(start, j)
                    if marker == "^" {
                        result.supBodies.append(bodyRange)
                    } else {
                        result.subBodies.append(bodyRange)
                    }
                }
                i = max(i + 1, j)
            }
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onFocusChange: (Bool) -> Void
        var onSubmit: () -> Void

        init(text: Binding<String>, onFocusChange: @escaping (Bool) -> Void, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onFocusChange = onFocusChange
            self.onSubmit = onSubmit
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange(false)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let sel = textView.selectedRange()
            EquationInputField.applyScriptStyling(to: textView)
            let clampedLoc = min(sel.location, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: sel.length))
            EquationInputField.syncTypingAttributes(for: textView)
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            EquationInputField.syncTypingAttributes(for: textView)
        }
    }
}

private final class EquationNSTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        onSubmit?()
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }
}

@MainActor
private final class PaletteHitTargets {
    weak var buttonView: NSView?
    weak var panelView: NSView?
    nonisolated(unsafe) var monitor: Any?

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private struct PaletteAnchorView: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NonHitNSView {
        let view = NonHitNSView()
        onAttach(view)
        return view
    }

    func updateNSView(_ nsView: NonHitNSView, context: Context) {
        onAttach(nsView)
    }

    final class NonHitNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
