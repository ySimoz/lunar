import AppKit
import SwiftUI

/// Design tokens and Unslop-compliant Monochrome Glassmorphism primitives for Lunar macOS.
public enum LunarTokens {
    // MARK: - Spacing (4pt grid)
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 24
    public static let space8: CGFloat = 32

    // MARK: - Radii
    public static let controlRadius: CGFloat = 8
    public static let cardRadius: CGFloat = 12
    public static let panelRadius: CGFloat = 16

    // MARK: - Hairlines & Strokes
    public static let hairlineWidth: CGFloat = 1
    public static let hairlineOpacity: Double = 0.08
    public static let hoverFillOpacity: Double = 0.05

    // MARK: - Motion
    public static let hoverAnimation: Animation = .easeOut(duration: 0.12)
    public static let revealAnimation: Animation = .easeOut(duration: 0.18)

    // MARK: - Monochrome Colors
    /// High-contrast neutral monochrome accent: crisp silver-white (#F4F4F5) in dark mode, ink-charcoal (#18181B) in light mode.
    public static func accent(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
        case .light:
            Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
        @unknown default:
            Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
        }
    }

    /// Standard neutral highlight ink used for progress bars, due counts, and active indicators.
    public static let neutralHighlight = Color.primary.opacity(0.78)

    /// Standard neutral track ink used behind progress bars and rings.
    public static let neutralTrack = Color.primary.opacity(0.10)

    public static func hairlineBorder() -> Color {
        Color.primary.opacity(hairlineOpacity)
    }

    /// Quiet 6pt neutral silver-slate dot color for CardType without green, amber, or purple tints.
    public static func cardTypeDotColor(_ type: CardType?, scheme: ColorScheme) -> Color {
        switch type {
        case .definition:
            scheme == .dark ? Color(white: 0.62) : Color(white: 0.42)
        case .theorem:
            scheme == .dark ? Color(white: 0.90) : Color(white: 0.16)
        case .example:
            scheme == .dark ? Color(white: 0.42) : Color(white: 0.60)
        case .none:
            Color.secondary.opacity(0.50)
        }
    }

    /// Quiet 6pt neutral monochrome dot color for SRS mastery stage.
    public static func masteryDotColor(_ stage: CardMasteryStage, scheme: ColorScheme) -> Color {
        switch stage {
        case .new:
            Color.primary.opacity(0.22)
        case .learning:
            Color.primary.opacity(0.44)
        case .reviewing:
            Color.primary.opacity(0.66)
        case .mastered:
            Color.primary.opacity(0.88)
        }
    }
}

/// Crisp monochrome primary action button style:
/// `#F4F4F5` fill with `#111318` text in Dark Mode, `#18181B` fill with `#FFFFFF` text in Light Mode.
public struct MonochromeProminentButtonStyle: ButtonStyle {
    public var compact: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        let fill = colorScheme == .dark
            ? Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
            : Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)
        let foreground = colorScheme == .dark
            ? Color(red: 17 / 255, green: 19 / 255, blue: 24 / 255)
            : Color.white
        let shape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)

        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                fill.opacity(isHovered ? 0.88 : 1.0),
                in: shape
            )
            .opacity(isEnabled ? 1.0 : 0.42)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1.0)
            .animation(LunarTokens.hoverAnimation, value: configuration.isPressed)
            .animation(LunarTokens.hoverAnimation, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Hairline glass card container layering `.regularMaterial` with a neutral window backing
/// (`Color(nsColor: .windowBackgroundColor).opacity(0.55)`) to block wallpaper color bleed,
/// plus a `1pt` `Color.primary.opacity(0.08)` hairline border.
public struct GlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var isSelected: Bool
    public var isHovered: Bool

    public init(
        cornerRadius: CGFloat = LunarTokens.cardRadius,
        isSelected: Bool = false,
        isHovered: Bool = false
    ) {
        self.cornerRadius = cornerRadius
        self.isSelected = isSelected
        self.isHovered = isHovered
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.68))
                    if isHovered {
                        shape.fill(Color.primary.opacity(LunarTokens.hoverFillOpacity))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    isSelected
                        ? Color.primary.opacity(0.32)
                        : LunarTokens.hairlineBorder(),
                    lineWidth: LunarTokens.hairlineWidth
                )
                .allowsHitTesting(false)
            }
            .animation(LunarTokens.hoverAnimation, value: isHovered)
    }
}

public extension View {
    func lunarGlassCard(
        cornerRadius: CGFloat = LunarTokens.cardRadius,
        isSelected: Bool = false,
        isHovered: Bool = false
    ) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, isSelected: isSelected, isHovered: isHovered))
    }

    func lunarWindowVibrancy() -> some View {
        modifier(LunarWindowVibrancyModifier())
    }

    @ViewBuilder
    func lunarSuppressTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

/// Applies neutral monochrome macOS window vibrancy backed against wallpaper color bleed.
public struct LunarWindowVibrancyModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .background {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.76)
                        .ignoresSafeArea(.all)
                }
                .containerBackground(.regularMaterial, for: .window)
        } else {
            content
                .background {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.76))
                    }
                    .ignoresSafeArea(.all)
                }
        }
    }
}

/// Single 4pt mastery progress bar with muted neutral track and high-contrast monochrome fill.
public struct MasteryBar: View {
    public let progress: Double

    public init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LunarTokens.neutralTrack)
                Capsule(style: .continuous)
                    .fill(LunarTokens.neutralHighlight)
                    .frame(width: max(0, width * progress))
            }
        }
        .frame(height: 4)
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

/// Small 6pt semantic indicator dot paired with a quiet label.
public struct CardTypeDot: View {
    public let type: CardType?
    @Environment(\.colorScheme) private var colorScheme

    public init(_ type: CardType?) {
        self.type = type
    }

    public var body: some View {
        Circle()
            .fill(LunarTokens.cardTypeDotColor(type, scheme: colorScheme))
            .frame(width: 6, height: 6)
    }
}

/// Subtle keyboard shortcut cap (e.g. `⌘N`, `⌘I`).
public struct KeycapLabel: View {
    public let text: String
    public var onProminentSurface: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(_ text: String, onProminentSurface: Bool = false) {
        self.text = text
        self.onProminentSurface = onProminentSurface
    }

    public var body: some View {
        let fg: Color = if onProminentSurface {
            colorScheme == .dark
                ? Color(red: 17 / 255, green: 19 / 255, blue: 24 / 255).opacity(0.78)
                : Color.white.opacity(0.85)
        } else {
            .secondary
        }
        let bg: Color = if onProminentSurface {
            colorScheme == .dark ? Color.black.opacity(0.08) : Color.white.opacity(0.14)
        } else {
            Color.primary.opacity(0.06)
        }
        let border: Color = if onProminentSurface {
            colorScheme == .dark ? Color.black.opacity(0.14) : Color.white.opacity(0.20)
        } else {
            LunarTokens.hairlineBorder()
        }

        Text(text)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            }
    }
}

/// Quiet press feedback button style (0.98 scale, zero bounce).
public struct QuietPressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(LunarTokens.hoverAnimation, value: configuration.isPressed)
    }
}

/// Minimalist monochrome glass button style with subtle fill, 1pt hairline border, and press feedback.
public struct MonochromeGlassButtonStyle: ButtonStyle {
    public var compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: shape
            )
            .overlay {
                shape.strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .onHover { hovering in
                isHovered = hovering
            }
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1.0)
            .animation(LunarTokens.hoverAnimation, value: configuration.isPressed)
            .animation(LunarTokens.hoverAnimation, value: isHovered)
    }
}

/// Monochrome frosted-glass dropdown menu replacing system blue `Picker(.menu)` arrows.
public struct LunarMenuPicker<SelectionValue: Hashable>: View {
    public struct Option: Identifiable {
        public let id: Int
        public let value: SelectionValue
        public let label: String

        public init(index: Int, value: SelectionValue, label: String) {
            self.id = index
            self.value = value
            self.label = label
        }
    }

    @Binding var selection: SelectionValue
    public let options: [Option]
    public var compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    public init(
        selection: Binding<SelectionValue>,
        options: [(SelectionValue, String)],
        compact: Bool = true
    ) {
        self._selection = selection
        self.options = options.enumerated().map { Option(index: $0.offset, value: $0.element.0, label: $0.element.1) }
        self.compact = compact
    }

    private var selectedLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)

        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: LunarTokens.space2) {
                Text(selectedLabel)
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 4 : 6)
            .background(
                Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: shape
            )
            .overlay {
                shape.strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1.0 : 0.45)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Frosted-glass segmented control with a sliding "glass drop" active indicator (`matchedGeometryEffect`).
public struct LunarSegmentedControl<OptionValue: Hashable>: View {
    public struct Segment: Identifiable {
        public let id: Int
        public let value: OptionValue
        public let label: String

        public init(index: Int, value: OptionValue, label: String) {
            self.id = index
            self.value = value
            self.label = label
        }
    }

    @Binding var selection: OptionValue
    public let segments: [Segment]
    public var fullWidth: Bool
    @Namespace private var dropNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    private static var dropSpring: Animation {
        .spring(response: 0.30, dampingFraction: 0.78)
    }

    public init(
        selection: Binding<OptionValue>,
        options: [(OptionValue, String)],
        fullWidth: Bool = false
    ) {
        self._selection = selection
        self.segments = options.enumerated().map { Segment(index: $0.offset, value: $0.element.0, label: $0.element.1) }
        self.fullWidth = fullWidth
    }

    public var body: some View {
        let trackShape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
        let pillShape = RoundedRectangle(cornerRadius: LunarTokens.controlRadius - 2, style: .continuous)

        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isActive = segment.value == selection

                Button {
                    withAnimation(Self.dropSpring) {
                        selection = segment.value
                    }
                } label: {
                    Text(segment.label)
                        .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .padding(.horizontal, LunarTokens.space3)
                        .padding(.vertical, 5)
                        .frame(maxWidth: fullWidth ? .infinity : nil)
                        .contentShape(Rectangle())
                        .background {
                            if isActive {
                                ZStack {
                                    pillShape.fill(.thinMaterial)
                                    pillShape.fill(
                                        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)
                                    )
                                }
                                .overlay {
                                    pillShape.strokeBorder(
                                        Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14),
                                        lineWidth: 1
                                    )
                                    .allowsHitTesting(false)
                                }
                                .shadow(
                                    color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08),
                                    radius: 4,
                                    y: 1
                                )
                                .matchedGeometryEffect(id: "lunar-glass-drop", in: dropNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.04),
            in: trackShape
        )
        .overlay {
            trackShape.strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

/// Monochrome Apple-style frosted-glass pill switch replacing macOS tick checkboxes,
/// with a specular track and a liquid-glass thumb that stretches smoothly when switching.
public struct MonochromeGlassToggleStyle: ToggleStyle {
    public var compact: Bool
    public var expandRow: Bool

    public init(compact: Bool = false, expandRow: Bool = true) {
        self.compact = compact
        self.expandRow = expandRow
    }

    public func makeBody(configuration: Configuration) -> some View {
        MonochromeGlassToggleRow(
            configuration: configuration,
            compact: compact,
            expandRow: expandRow
        )
    }
}

private struct MonochromeGlassToggleRow: View {
    let configuration: ToggleStyleConfiguration
    let compact: Bool
    let expandRow: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var isMorphing = false
    @State private var dragStartProgress: CGFloat?
    @State private var dragProgress: CGFloat?
    @State private var morphGeneration = 0

    private var trackWidth: CGFloat { compact ? 40 : 46 }
    private var trackHeight: CGFloat { compact ? 22 : 24 }
    private var inset: CGFloat { 2 }
    private var thumbRestWidth: CGFloat { compact ? 22 : 26 }
    private var thumbRestHeight: CGFloat { trackHeight - inset * 2 }
    private var travel: CGFloat { max(1, trackWidth - inset * 2 - thumbRestWidth) }
    private var isBubbleOpen: Bool { isDragging || isMorphing }
    private var currentProgress: CGFloat { dragProgress ?? (configuration.isOn ? 1.0 : 0.0) }

    var body: some View {
        HStack(spacing: LunarTokens.space2) {
            configuration.label
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isEnabled else { return }
                    triggerTapSwitch()
                }

            if expandRow {
                Spacer(minLength: LunarTokens.space3)
            }

            switchPill
        }
        .opacity(isEnabled ? 1.0 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction {
            guard isEnabled else { return }
            triggerTapSwitch()
        }
    }

    private var switchPill: some View {
        let thumbWidth = isBubbleOpen ? thumbRestWidth + 6 : thumbRestWidth
        let thumbHeight = isBubbleOpen ? thumbRestHeight + 5 : thumbRestHeight
        let xOffset = inset + currentProgress * travel - (thumbWidth - thumbRestWidth) / 2

        let trackFill: Color = if colorScheme == .dark {
            Color.white.opacity(0.11 + Double(currentProgress) * (isHovered ? 0.28 : 0.22))
        } else {
            Color.black.opacity(0.09 + Double(currentProgress) * (isHovered ? 0.76 : 0.70))
        }

        let rimGradient = LinearGradient(
            colors: [
                Color.white.opacity(0.18 + Double(currentProgress) * 0.18),
                Color.primary.opacity(0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        // Resting pill is crisp frosted white; when dragged or switching, the glass bubble opens up translucent with specular refraction.
        let bubbleGradient = LinearGradient(
            colors: isBubbleOpen
                ? [
                    Color.white.opacity(colorScheme == .dark ? 0.56 : 0.68),
                    Color.white.opacity(colorScheme == .dark ? 0.18 : 0.26),
                    Color.white.opacity(colorScheme == .dark ? 0.42 : 0.54)
                ]
                : [
                    Color.white.opacity(0.98),
                    Color.white.opacity(0.92)
                ],
            startPoint: .top,
            endPoint: .bottom
        )

        let bubbleRim = LinearGradient(
            colors: [
                Color.white.opacity(isBubbleOpen ? 0.94 : 0.68),
                Color.white.opacity(isBubbleOpen ? 0.28 : 0.20),
                Color.white.opacity(isBubbleOpen ? 0.72 : 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        return ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(trackFill)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(rimGradient, lineWidth: 1)
                        .allowsHitTesting(false)
                }

            Capsule(style: .continuous)
                .fill(bubbleGradient)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(bubbleRim, lineWidth: isBubbleOpen ? 1.15 : 0.75)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: Color.black.opacity(
                        isBubbleOpen
                            ? (colorScheme == .dark ? 0.40 : 0.22)
                            : (colorScheme == .dark ? 0.28 : 0.16)
                    ),
                    radius: isBubbleOpen ? 5 : 2.5,
                    y: isBubbleOpen ? 2 : 1
                )
                .frame(width: thumbWidth, height: thumbHeight)
                .offset(x: xOffset)
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Rectangle().inset(by: -4))
        .onHover { hovering in
            isHovered = hovering
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled else { return }
                    if dragStartProgress == nil {
                        dragStartProgress = configuration.isOn ? 1.0 : 0.0
                        withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
                            isDragging = true
                        }
                    }
                    let start = dragStartProgress ?? (configuration.isOn ? 1.0 : 0.0)
                    dragProgress = min(1.0, max(0.0, start + value.translation.width / travel))
                }
                .onEnded { value in
                    guard isEnabled else {
                        dragStartProgress = nil
                        dragProgress = nil
                        isDragging = false
                        return
                    }
                    let start = dragStartProgress ?? (configuration.isOn ? 1.0 : 0.0)
                    let moved = abs(value.translation.width)
                    if moved < 3 {
                        dragStartProgress = nil
                        dragProgress = nil
                        isDragging = false
                        triggerTapSwitch()
                        return
                    }

                    let current = dragProgress ?? start
                    let hasFlickVelocity = abs(value.predictedEndTranslation.width - value.translation.width) > 12
                    let targetProgress: CGFloat = (moved < travel * 0.45 && hasFlickVelocity)
                        ? min(1.0, max(0.0, start + value.predictedEndTranslation.width / travel))
                        : current
                    let nextOn = targetProgress >= 0.5

                    withAnimation(.spring(response: 0.26, dampingFraction: 0.80)) {
                        dragStartProgress = nil
                        dragProgress = nil
                        isDragging = false
                        configuration.isOn = nextOn
                    }
                }
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isBubbleOpen)
        .animation(.spring(response: 0.28, dampingFraction: 0.80), value: configuration.isOn)
    }

    private func triggerTapSwitch() {
        morphGeneration &+= 1
        let token = morphGeneration
        withAnimation(.spring(response: 0.18, dampingFraction: 0.78)) {
            isMorphing = true
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
            configuration.isOn.toggle()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard morphGeneration == token else { return }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                isMorphing = false
            }
        }
    }
}

public extension View {
    /// Reports this view's frame in top-left `NSWindow.contentView` coordinates across split views.
    func reportWindowFrame(onChange: @escaping (CGRect) -> Void) -> some View {
        background {
            WindowFrameReporterView(onChange: onChange)
                .allowsHitTesting(false)
        }
    }
}

public enum LunarWindowCoordinates {
    /// Returns the current mouse pointer in top-left `NSWindow.contentView` coordinates.
    @MainActor
    public static func currentPointerLocation() -> CGPoint? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let root = window.contentView else { return nil }
        let winPt = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: winPt.x, y: root.bounds.height - winPt.y)
    }
}

private struct WindowFrameReporterView: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> FrameObserverNSView {
        let view = FrameObserverNSView()
        view.onFrame = onChange
        return view
    }

    func updateNSView(_ nsView: FrameObserverNSView, context: Context) {
        nsView.onFrame = onChange
        nsView.reportIfNeeded()
    }
}

private final class FrameObserverNSView: NSView {
    var onFrame: ((CGRect) -> Void)?
    private var lastReported: CGRect = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportIfNeeded()
    }

    override func layout() {
        super.layout()
        reportIfNeeded()
    }

    func reportIfNeeded() {
        guard let window, let root = window.contentView else { return }
        let inWindow = convert(bounds, to: nil)
        let topLeft = CGRect(
            x: inWindow.minX,
            y: root.bounds.height - inWindow.maxY,
            width: inWindow.width,
            height: inWindow.height
        )
        if abs(topLeft.minX - lastReported.minX) > 0.5
            || abs(topLeft.minY - lastReported.minY) > 0.5
            || abs(topLeft.width - lastReported.width) > 0.5
            || abs(topLeft.height - lastReported.height) > 0.5
        {
            lastReported = topLeft
            let callback = onFrame
            DispatchQueue.main.async {
                callback?(topLeft)
            }
        }
    }
}
