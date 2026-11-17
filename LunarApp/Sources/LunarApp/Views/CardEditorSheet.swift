import AppKit
import SwiftUI

/// Split-view modal sheet for creating or editing a multi-layer `Flashcard`.
/// Left pane: non-scrolling 2-tab flex editor (`Prompt & Answer` | `Layers & Notes`) with `⌘K` symbol popover.
/// Right pane: single live KaTeX `MathView` preview with zero per-section WebKit scrollbars.
public struct CardEditorSheet: View {
    public enum ActiveField: Hashable {
        case front
        case back
        case explanation
        case layerContent(String)

        var displayName: String {
            switch self {
            case .front: "Front"
            case .back: "Back"
            case .explanation: "Notes"
            case .layerContent: "Layer"
            }
        }
    }

    private enum EditorTab: String, CaseIterable, Identifiable {
        case promptAndAnswer = "Prompt & Answer"
        case layersAndNotes = "Layers & Notes"

        var id: String { rawValue }
    }

    public let deck: Deck
    public let existingCard: Flashcard?
    public let fontFamily: String
    public let fontSize: String
    public let onSave: (Flashcard) -> Void

    @State private var topic: String
    @State private var cardType: CardType
    @State private var difficulty: Difficulty
    @State private var front: String
    @State private var back: String
    @State private var layers: [CardLayer]
    @State private var explanation: String
    @State private var tagsText: String

    @State private var activeTab: EditorTab = .promptAndAnswer
    @FocusState private var focusedField: ActiveField?
    @State private var lastActiveField: ActiveField = .front
    @State private var showSymbolPopover = false

    @Environment(\.dismiss) private var dismiss

    public init(
        deck: Deck,
        existingCard: Flashcard? = nil,
        initialTopic: String? = nil,
        fontFamily: String = "serif",
        fontSize: String = "base",
        onSave: @escaping (Flashcard) -> Void
    ) {
        self.deck = deck
        self.existingCard = existingCard
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.onSave = onSave

        _topic = State(initialValue: existingCard?.topic ?? initialTopic ?? deck.chapters.first ?? "")
        _cardType = State(initialValue: existingCard?.cardType ?? .definition)
        _difficulty = State(initialValue: existingCard?.difficulty ?? deck.difficulty)
        _front = State(initialValue: existingCard?.front ?? "")
        _back = State(initialValue: existingCard?.back ?? "")
        _layers = State(initialValue: existingCard?.layers ?? [])
        _explanation = State(initialValue: existingCard?.explanation ?? "")
        _tagsText = State(initialValue: (existingCard?.tags ?? []).joined(separator: ", "))
    }

    private var canSave: Bool {
        !front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var combinedPreviewContent: String {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBack = back.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = explanation.trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []

        if !trimmedFront.isEmpty {
            sections.append("#### Prompt\n\(wrapRawLatexIfNeeded(trimmedFront))")
        }

        if !layers.isEmpty {
            var layerBlocks: [String] = []
            for (index, layer) in layers.enumerated() {
                let rawTitle = layer.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let stepTitle = rawTitle.isEmpty ? "Step \(index + 1)" : rawTitle
                let stepBody = layer.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let formattedBody = stepBody.isEmpty ? "_Empty step_" : wrapRawLatexIfNeeded(stepBody)
                layerBlocks.append("**\(stepTitle)**\n\(formattedBody)")
            }
            sections.append("#### Layers\n\(layerBlocks.joined(separator: "\n\n"))")
        }

        if !trimmedBack.isEmpty {
            sections.append("#### Answer\n\(wrapRawLatexIfNeeded(trimmedBack))")
        }

        if !trimmedNotes.isEmpty {
            sections.append("#### Notes\n\(wrapRawLatexIfNeeded(trimmedNotes))")
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    private func wrapRawLatexIfNeeded(_ text: String) -> String {
        let candidate = MathParser.shouldAttemptRawLatex(text)
        guard candidate.candidate else { return text }
        return candidate.displayMode ? "$$\n\(text)\n$$" : "$\(text)$"
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            HSplitView {
                formPane
                    .frame(minWidth: 390, idealWidth: 440)

                previewPane
                    .frame(minWidth: 350, idealWidth: 420)
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .onChange(of: focusedField) { _, newFocus in
            if let newFocus {
                lastActiveField = newFocus
            }
        }
        .onChange(of: activeTab) { _, newTab in
            switch newTab {
            case .promptAndAnswer:
                if case .explanation = lastActiveField {
                    lastActiveField = .front
                } else if case .layerContent = lastActiveField {
                    lastActiveField = .front
                }
            case .layersAndNotes:
                if lastActiveField == .front || lastActiveField == .back {
                    lastActiveField = layers.first.map { .layerContent($0.id) } ?? .explanation
                }
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: LunarTokens.space3) {
            Text(existingCard == nil ? "New Card" : "Edit Card")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button {
                showSymbolPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sum")
                        .font(.system(size: 13, weight: .medium))
                    Text("Symbols")
                        .font(.system(size: 12, weight: .medium))
                    KeycapLabel("⌘K")
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("k", modifiers: .command)
            .popover(isPresented: $showSymbolPopover, arrowEdge: .bottom) {
                MathSymbolPopover(activeFieldLabel: lastActiveField.displayName) { markup in
                    insertMarkup(markup, into: lastActiveField)
                }
            }

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(existingCard == nil ? "Create" : "Save") {
                commit()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(MonochromeProminentButtonStyle())
            .disabled(!canSave)
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space4)
    }

    private var formPane: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            // Compact horizontal Classification row
            HStack(alignment: .bottom, spacing: LunarTokens.space3) {
                VStack(alignment: .leading, spacing: LunarTokens.space1) {
                    Text("Chapter")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("", text: $topic, prompt: Text(""))
                            .accessibilityLabel("Chapter")
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        if !deck.chapters.isEmpty {
                            Menu {
                                Button("General") { topic = "" }
                                Divider()
                                ForEach(deck.chapters, id: \.self) { chapter in
                                    Button(chapter) { topic = chapter }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 22)
                                    .background(
                                        Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Choose Chapter")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: LunarTokens.space1) {
                    Text("Type")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    LunarMenuPicker(
                        selection: $cardType,
                        options: CardType.allCases.map { ($0, $0.displayName) }
                    )
                }

                VStack(alignment: .leading, spacing: LunarTokens.space1) {
                    Text("Difficulty")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    LunarMenuPicker(
                        selection: $difficulty,
                        options: Difficulty.allCases.map { ($0, $0.displayName) }
                    )
                }
            }

            LunarSegmentedControl(
                selection: $activeTab,
                options: EditorTab.allCases.map { tab in
                    let title = (tab == .layersAndNotes && !layers.isEmpty)
                        ? "\(tab.rawValue) (\(layers.count))"
                        : tab.rawValue
                    return (tab, title)
                },
                fullWidth: true
            )

            if activeTab == .promptAndAnswer {
                promptAndAnswerFields
            } else {
                layersAndNotesFields
            }
        }
        .padding(LunarTokens.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var promptAndAnswerFields: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Front")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                CleanTextEditor(text: $front)
                    .padding(LunarTokens.space2)
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                    }
                    .focused($focusedField, equals: .front)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Back")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                CleanTextEditor(text: $back)
                    .padding(LunarTokens.space2)
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                    }
                    .focused($focusedField, equals: .back)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var layersAndNotesFields: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                HStack {
                    Text("Progressive Layers")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let newLayer = CardLayer(
                            id: "layer-\(UUID().uuidString.prefix(8))",
                            title: "Step \(layers.count + 1)",
                            content: ""
                        )
                        layers.append(newLayer)
                        lastActiveField = .layerContent(newLayer.id)
                    } label: {
                        Label("Add Layer", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if layers.isEmpty {
                    Text("No layers added")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, LunarTokens.space2)
                } else {
                    ScrollView {
                        VStack(spacing: LunarTokens.space2) {
                            ForEach($layers) { $layer in
                                VStack(alignment: .leading, spacing: LunarTokens.space2) {
                                    HStack {
                                        TextField("", text: $layer.title, prompt: Text(""))
                                            .accessibilityLabel("Step title")
                                            .font(.system(size: 12, weight: .medium))
                                            .textFieldStyle(.roundedBorder)
                                        Button {
                                            layers.removeAll { $0.id == layer.id }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Remove layer")
                                    }
                                    CleanTextEditor(text: $layer.content)
                                        .padding(LunarTokens.space2)
                                        .frame(minHeight: 54, maxHeight: 84)
                                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                                                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                                        }
                                        .focused($focusedField, equals: .layerContent(layer.id))
                                }
                                .padding(LunarTokens.space3)
                                .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }

            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                CleanTextEditor(text: $explanation)
                    .padding(LunarTokens.space2)
                    .frame(minHeight: 80, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                    }
                    .focused($focusedField, equals: .explanation)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Tags")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $tagsText, prompt: Text(""))
                    .accessibilityLabel("Tags")
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewPane: some View {
        let previewBody = combinedPreviewContent

        return ScrollView {
            VStack(alignment: .leading, spacing: LunarTokens.space4) {
                Text("Preview")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: LunarTokens.space4) {
                    HStack(spacing: LunarTokens.space2) {
                        CardTypeDot(cardType)
                        Text(cardType.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(difficulty.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(topic)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        MathView(
                            content: previewBody,
                            fontFamily: fontFamily,
                            fontSize: fontSize,
                            minHeight: 160
                        )
                        .opacity(previewBody.isEmpty ? 0 : 1)

                        if previewBody.isEmpty {
                            Text("Enter prompt and answer to preview rendered math.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .padding(.top, LunarTokens.space2)
                        }
                    }

                    if !parsedTags.isEmpty {
                        HStack(spacing: LunarTokens.space2) {
                            ForEach(parsedTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, LunarTokens.space2)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                    }
                }
                .padding(LunarTokens.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
            }
            .padding(LunarTokens.space5)
        }
        .background(Color.primary.opacity(0.015))
    }

    private func insertMarkup(_ markup: String, into field: ActiveField) {
        func append(_ current: String) -> String {
            guard !current.isEmpty else { return markup }
            if current.hasSuffix(" ") || current.hasSuffix("\n") {
                return current + markup
            }
            return current + " " + markup
        }

        switch field {
        case .front:
            front = append(front)
            activeTab = .promptAndAnswer
            focusedField = .front
        case .back:
            back = append(back)
            activeTab = .promptAndAnswer
            focusedField = .back
        case .explanation:
            explanation = append(explanation)
            activeTab = .layersAndNotes
            focusedField = .explanation
        case .layerContent(let id):
            if let idx = layers.firstIndex(where: { $0.id == id }) {
                layers[idx].content = append(layers[idx].content)
                activeTab = .layersAndNotes
                focusedField = .layerContent(id)
            } else {
                front = append(front)
                activeTab = .promptAndAnswer
                focusedField = .front
            }
        }
    }

    private func commit() {
        guard canSave else { return }
        var draft = existingCard ?? Flashcard(
            deckId: deck.id,
            front: front,
            back: back
        )
        draft.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cardType = cardType
        draft.difficulty = difficulty
        draft.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.layers = layers.map {
            CardLayer(
                id: $0.id.isEmpty ? "layer-\(UUID().uuidString.prefix(8))" : $0.id,
                title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        draft.explanation = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.tags = parsedTags
        onSave(draft)
        dismiss()
    }
}

/// Transparent monospace `NSTextView` with overlay autohiding scrollers and smart-quote
/// substitution disabled so LaTeX primes/quotes remain untouched and no permanent bar renders.
private struct CleanTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selected
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
        }
    }
}
