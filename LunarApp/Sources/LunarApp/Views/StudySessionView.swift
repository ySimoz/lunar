import SwiftUI

/// Concrete study session launch request shared by Library, Deck Detail, and Crash Recovery.
public struct StudyLaunchRequest: Identifiable, Sendable {
    public let id = UUID()
    public let deck: Deck
    public let cards: [Flashcard]
    public let mode: StudyMode
    public let startingLives: Int?
    public let deckIds: [String]?
    public let deckTitles: [String]?
    public let restoredState: ActiveSessionState?

    public init(
        deck: Deck,
        cards: [Flashcard],
        mode: StudyMode = .standard,
        startingLives: Int? = nil,
        deckIds: [String]? = nil,
        deckTitles: [String]? = nil,
        restoredState: ActiveSessionState? = nil
    ) {
        self.deck = deck
        self.cards = cards
        self.mode = mode
        self.startingLives = startingLives
        self.deckIds = deckIds
        self.deckTitles = deckTitles
        self.restoredState = restoredState
    }
}

/// Distraction-free study stage with single centered glass card, inline multi-layer
/// reveal, SM-2 rating bar, keyboard shortcuts, and crash-recovery interruption flow.
public struct StudySessionView: View {
    @State private var vm: StudySessionViewModel
    @State private var showCardJump = false
    @State private var showOptions = false
    @State private var showExitPrompt = false
    @State private var isExplanationExpanded = false

    public let onClose: (() -> Void)?
    public let onSessionFinished: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        request: StudyLaunchRequest,
        preferences: UserPreferences,
        client: (any CoreClientProtocol)?,
        onClose: (() -> Void)? = nil,
        onSessionFinished: @escaping @MainActor () async -> Void
    ) {
        _vm = State(initialValue: StudySessionViewModel(
            deck: request.deck,
            cards: request.cards,
            mode: request.mode,
            startingLives: request.startingLives,
            deckIds: request.deckIds,
            deckTitles: request.deckTitles,
            preferences: preferences,
            client: client,
            restoredState: request.restoredState
        ))
        self.onClose = onClose
        self.onSessionFinished = onSessionFinished
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            hairlineProgressStrip

            if vm.isCompleted {
                completionSummary
            } else if let card = vm.currentCard {
                ScrollView {
                    centeredStudyCard(card)
                        .padding(.horizontal, LunarTokens.space6)
                        .padding(.vertical, LunarTokens.space6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                bottomRecallBar(for: card)
            } else {
                ContentUnavailableView(
                    "No Cards in Session",
                    systemImage: "rectangle.stack",
                    description: Text("Select cards to study.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
        .background { keyboardShortcutBindings }
        .task {
            await vm.startSession()
        }
        .task(id: vm.isCompleted) {
            guard !vm.isCompleted else { return }
            while !Task.isCancelled && !vm.isCompleted {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled && !vm.isCompleted {
                    vm.tickSecond()
                }
            }
        }
        .onChange(of: vm.currentIndex) { _, _ in
            isExplanationExpanded = false
        }
        .confirmationDialog(
            "Leave Study Session",
            isPresented: $showExitPrompt,
            titleVisibility: .visible
        ) {
            if vm.reviewedCount > 0 {
                Button("Finish Early") {
                    Task {
                        await vm.finishEarly()
                        await onSessionFinished()
                    }
                }
            }
            Button("Pause & Resume Later") {
                Task {
                    await vm.pauseAndSaveForLater()
                    await onSessionFinished()
                    closeSession()
                }
            }
            Button("Discard Session", role: .destructive) {
                Task {
                    await vm.discardSession()
                    await onSessionFinished()
                    closeSession()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reviewed \(vm.reviewedCount) of \(vm.totalCards) cards.")
        }
    }

    // MARK: - Top Bar & Hairline Progress

    private var topBar: some View {
        HStack(spacing: LunarTokens.space3) {
            Button {
                handleBackAction()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 16)

            Text(vm.deck.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if vm.isGauntletMode && !vm.isCompleted {
                gauntletStatusPill
                Spacer()
            }

            if !vm.isCompleted && vm.totalCards > 0 {
                Text("\(vm.currentIndex + 1) / \(vm.totalCards)")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if vm.showTimer && !vm.isCompleted {
                Text(vm.formattedElapsedTime)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, LunarTokens.space2)
            }

            undoButton

            Button {
                showCardJump.toggle()
            } label: {
                Image(systemName: "list.number")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Jump to Card")
            .disabled(vm.isCompleted || vm.queue.isEmpty)
            .popover(isPresented: $showCardJump, arrowEdge: .bottom) {
                cardJumpPopover
            }

            Button {
                showOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Session Options")
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                sessionOptionsPopover
            }
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space3)
    }

    private var undoButton: some View {
        Button {
            Task { await vm.undoLastRating() }
        } label: {
            HStack(spacing: LunarTokens.space1) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(MonochromeGlassButtonStyle(compact: true))
        .disabled(!vm.canUndo)
        .help("Undo last rating (⌘Z)")
    }

    private var hairlineProgressStrip: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LunarTokens.neutralTrack)
                Rectangle()
                    .fill(LunarTokens.neutralHighlight)
                    .frame(width: max(0, proxy.size.width * vm.progressFraction))
                    .animation(LunarTokens.revealAnimation, value: vm.progressFraction)
            }
        }
        .frame(height: 2)
    }

    // MARK: - Centered Glass Card

    private func centeredStudyCard(_ card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space5) {
            // Quiet card header
            HStack(spacing: LunarTokens.space2) {
                CardTypeDot(card.cardType)
                Text(card.cardType?.displayName ?? "Card")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if !card.topic.isEmpty {
                    Text(card.topic)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Prompt
            MathView(
                content: card.front,
                fontFamily: vm.preferences.fontFamily,
                fontSize: vm.preferences.fontSize
            )

            // Inline Multi-Layer Reveal (inside the same card, separated by 1px Dividers)
            if vm.revealedLayersCount > 0 {
                let visibleLayers = Array(card.layers.prefix(vm.revealedLayersCount))
                ForEach(Array(visibleLayers.enumerated()), id: \.element.id) { index, layer in
                    Divider()
                    VStack(alignment: .leading, spacing: LunarTokens.space2) {
                        Text(layer.title.isEmpty ? "Step \(index + 1)" : layer.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        MathView(
                            content: layer.content,
                            fontFamily: vm.preferences.fontFamily,
                            fontSize: vm.preferences.fontSize
                        )
                    }
                    .transition(.opacity)
                }
            }

            // Answer & collapsed Derivation Notes
            if vm.isAnswerRevealed {
                Divider()

                VStack(alignment: .leading, spacing: LunarTokens.space2) {
                    Text("Answer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LunarTokens.neutralHighlight)

                    MathView(
                        content: card.back,
                        fontFamily: vm.preferences.fontFamily,
                        fontSize: vm.preferences.fontSize
                    )
                }
                .transition(.opacity)

                if !card.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Divider()

                    DisclosureGroup("Derivation Notes", isExpanded: $isExplanationExpanded) {
                        MathView(
                            content: card.explanation,
                            fontFamily: vm.preferences.fontFamily,
                            fontSize: "sm"
                        )
                        .padding(.top, LunarTokens.space2)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(LunarTokens.space6)
        .frame(maxWidth: 680, alignment: .leading)
        .lunarGlassCard(cornerRadius: LunarTokens.panelRadius)
        .frame(maxWidth: .infinity)
        .animation(LunarTokens.revealAnimation, value: vm.revealedLayersCount)
        .animation(LunarTokens.revealAnimation, value: vm.isAnswerRevealed)
    }

    // MARK: - Pinned Bottom Recall Bar

    @ViewBuilder
    private func bottomRecallBar(for card: Flashcard) -> some View {
        HStack {
            Spacer()
            if !vm.isAnswerRevealed {
                preRevealBar(for: card)
                    .frame(maxWidth: 680)
            } else if vm.isGauntletMode {
                gauntletBinaryBar
                    .frame(maxWidth: 680)
            } else {
                postRevealRatingBar
                    .frame(maxWidth: 680)
            }
            Spacer()
        }
        .padding(.horizontal, LunarTokens.space6)
        .padding(.vertical, LunarTokens.space4)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
        }
    }

    private func preRevealBar(for card: Flashcard) -> some View {
        HStack(spacing: LunarTokens.space3) {
            if vm.hasMoreLayersToReveal {
                Button {
                    vm.revealNextStepOrAnswer()
                } label: {
                    HStack(spacing: LunarTokens.space2) {
                        Text("Show Next Step (\(vm.revealedLayersCount + 1)/\(card.layers.count))")
                            .monospacedDigit()
                        KeycapLabel("Space", onProminentSurface: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MonochromeProminentButtonStyle())

                Button("Show Answer") {
                    vm.revealAnswer()
                }
                .buttonStyle(.bordered)
                .font(.system(size: 13, weight: .medium))
            } else {
                Button {
                    vm.revealAnswer()
                } label: {
                    HStack(spacing: LunarTokens.space2) {
                        Text("Show Answer")
                        KeycapLabel("Space", onProminentSurface: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(MonochromeProminentButtonStyle())
            }
        }
    }

    private var gauntletStatusPill: some View {
        HStack(spacing: LunarTokens.space3) {
            if let starting = vm.startingLives, let remaining = vm.livesLeft {
                if starting <= 5 {
                    HStack(spacing: 3) {
                        ForEach(0..<starting, id: \.self) { index in
                            Image(systemName: index < remaining ? "heart.fill" : "heart")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(index < remaining ? Color.primary : Color.secondary.opacity(0.45))
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("\(remaining)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "infinity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Unlimited")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 12)

            HStack(spacing: 4) {
                Image(systemName: "flame")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(vm.currentStreak > 0 ? LunarTokens.neutralHighlight : .secondary)
                Text("\(vm.currentStreak)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(vm.currentStreak > 0 ? LunarTokens.neutralHighlight : .secondary)
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
        }
    }

    private var gauntletBinaryBar: some View {
        HStack(spacing: LunarTokens.space3) {
            Button {
                Task { await vm.submitGauntletAnswer(knewIt: false) }
            } label: {
                HStack(spacing: LunarTokens.space2) {
                    Text("Missed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if vm.livesLeft != nil {
                        Text("-1 life")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    KeycapLabel("1 / ←")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LunarTokens.space2 + 2)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                        .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                }
            }
            .buttonStyle(QuietPressButtonStyle())
            .disabled(vm.isSubmitting)

            Button {
                Task { await vm.submitGauntletAnswer(knewIt: true) }
            } label: {
                HStack(spacing: LunarTokens.space2) {
                    Text("Knew It")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    KeycapLabel("2 / →")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, LunarTokens.space2 + 2)
                .background(
                    Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                }
            }
            .buttonStyle(QuietPressButtonStyle())
            .disabled(vm.isSubmitting)
        }
    }

    private var postRevealRatingBar: some View {
        HStack(spacing: LunarTokens.space3) {
            RatingButton(
                title: "Again",
                interval: vm.predictions[1]?.label ?? "1d",
                keycap: "1",
                isPrimary: false,
                isSubmitting: vm.isSubmitting
            ) {
                Task { await vm.submitRating(1) }
            }

            RatingButton(
                title: "Hard",
                interval: vm.predictions[2]?.label ?? "1d",
                keycap: "2",
                isPrimary: false,
                isSubmitting: vm.isSubmitting
            ) {
                Task { await vm.submitRating(2) }
            }

            RatingButton(
                title: "Good",
                interval: vm.predictions[3]?.label ?? "1d",
                keycap: "3",
                isPrimary: true,
                isSubmitting: vm.isSubmitting
            ) {
                Task { await vm.submitRating(3) }
            }

            RatingButton(
                title: "Easy",
                interval: vm.predictions[4]?.label ?? "4d",
                keycap: "4",
                isPrimary: false,
                isSubmitting: vm.isSubmitting
            ) {
                Task { await vm.submitRating(4) }
            }
        }
    }

    // MARK: - Popovers

    private var cardJumpPopover: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Cards in Session")
                .font(.system(size: 13, weight: .semibold))

            Divider()

            ScrollView {
                VStack(spacing: LunarTokens.space1) {
                    ForEach(Array(vm.queue.enumerated()), id: \.element.id) { idx, card in
                        let isCurrent = idx == vm.currentIndex
                        let isReviewed = vm.reviewedCardIDs.contains(card.id)
                        Button {
                            showCardJump = false
                            Task { await vm.jumpToCard(at: idx) }
                        } label: {
                            HStack(spacing: LunarTokens.space2) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)

                                CardTypeDot(card.cardType)

                                Text(card.front.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                if isReviewed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LunarTokens.neutralHighlight)
                                }
                            }
                            .padding(.horizontal, LunarTokens.space2)
                            .padding(.vertical, 6)
                            .background(
                                isCurrent ? Color.primary.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(LunarTokens.space4)
        .frame(width: 340)
    }

    private var sessionOptionsPopover: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Session Options")
                .font(.system(size: 13, weight: .semibold))

            Group {
                Toggle("Shuffle remaining cards", isOn: Binding(
                    get: { vm.isShuffled },
                    set: { _ in
                        Task { await vm.toggleShuffle() }
                    }
                ))

                Toggle("Sound cues", isOn: $vm.soundEnabled)

                Toggle("Show elapsed timer", isOn: $vm.showTimer)
            }
            .font(.system(size: 12))
            .toggleStyle(MonochromeGlassToggleStyle())

            Divider()

            Button("Restart Session") {
                showOptions = false
                Task { await vm.restart() }
            }
            .font(.system(size: 12, weight: .medium))

            Divider()

            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 12, weight: .semibold))

                ShortcutRow(action: "Next step / Reveal", keys: ["Space", "↓"])
                ShortcutRow(action: "Rate recall", keys: ["1–4"])
                ShortcutRow(action: "Undo rating", keys: ["⌘Z"])
                ShortcutRow(action: "Toggle shuffle", keys: ["S"])
                ShortcutRow(action: "Leave session", keys: ["Esc"])
            }
        }
        .padding(LunarTokens.space4)
        .frame(width: 260)
    }

    // MARK: - Calm Completion Summary

    private var completionTitle: String {
        if vm.isOutOfLives { return "Out of Lives" }
        if vm.isGauntletMode { return "Gauntlet Complete" }
        return "Session Complete"
    }

    private var completionSummary: some View {
        VStack(spacing: LunarTokens.space6) {
            VStack(spacing: LunarTokens.space2) {
                Image(systemName: vm.isOutOfLives ? "heart.slash" : "checkmark.circle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(vm.isOutOfLives ? .secondary : LunarTokens.neutralHighlight)

                Text(completionTitle)
                    .font(.system(size: 20, weight: .semibold))

                Text(vm.deck.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: LunarTokens.space6) {
                CompletionStat(label: "Reviewed", value: "\(vm.reviewedCount)")
                Divider().frame(height: 28)
                CompletionStat(label: "Accuracy", value: "\(vm.accuracyPercent)%")
                if vm.isGauntletMode {
                    Divider().frame(height: 28)
                    CompletionStat(label: "Best Streak", value: "\(vm.bestStreak)")
                    if let lives = vm.livesLeft {
                        Divider().frame(height: 28)
                        CompletionStat(label: "Lives Left", value: "\(lives)")
                    }
                }
                Divider().frame(height: 28)
                CompletionStat(label: "Elapsed", value: vm.formattedElapsedTime)
            }
            .padding(.horizontal, LunarTokens.space6)
            .padding(.vertical, LunarTokens.space4)
            .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)

            HStack(spacing: LunarTokens.space3) {
                Button("Study Again") {
                    Task { await vm.restart() }
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    Task {
                        await onSessionFinished()
                        closeSession()
                    }
                }
                .buttonStyle(MonochromeProminentButtonStyle())
            }
        }
        .padding(LunarTokens.space8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcutBindings: some View {
        Group {
            Button("") {
                guard !vm.isCompleted, !showExitPrompt, !showCardJump, !showOptions else { return }
                vm.revealNextStepOrAnswer()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("") {
                guard !vm.isCompleted, !showExitPrompt, !showCardJump, !showOptions else { return }
                vm.revealNextStepOrAnswer()
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, !showExitPrompt else { return }
                if vm.isGauntletMode {
                    Task { await vm.submitGauntletAnswer(knewIt: false) }
                } else {
                    Task { await vm.submitRating(1) }
                }
            }
            .keyboardShortcut("1", modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, !showExitPrompt else { return }
                if vm.isGauntletMode {
                    Task { await vm.submitGauntletAnswer(knewIt: true) }
                } else {
                    Task { await vm.submitRating(2) }
                }
            }
            .keyboardShortcut("2", modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, vm.isGauntletMode, !showExitPrompt else { return }
                Task { await vm.submitGauntletAnswer(knewIt: false) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, vm.isGauntletMode, !showExitPrompt else { return }
                Task { await vm.submitGauntletAnswer(knewIt: true) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, !vm.isGauntletMode, !showExitPrompt else { return }
                Task { await vm.submitRating(3) }
            }
            .keyboardShortcut("3", modifiers: [])

            Button("") {
                guard !vm.isCompleted, vm.isAnswerRevealed, !vm.isGauntletMode, !showExitPrompt else { return }
                Task { await vm.submitRating(4) }
            }
            .keyboardShortcut("4", modifiers: [])

            Button("") {
                guard !vm.isCompleted, !showExitPrompt else { return }
                Task { await vm.toggleShuffle() }
            }
            .keyboardShortcut("s", modifiers: [])

            Button("") {
                guard vm.canUndo, !showExitPrompt, !showCardJump, !showOptions else { return }
                Task { await vm.undoLastRating() }
            }
            .keyboardShortcut("z", modifiers: .command)

            Button("") {
                handleBackAction()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .hidden()
    }

    private func handleBackAction() {
        if vm.isCompleted || vm.queue.isEmpty {
            Task {
                await onSessionFinished()
                closeSession()
            }
        } else {
            showExitPrompt = true
        }
    }

    private func closeSession() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

// MARK: - Supporting Views

private struct RatingButton: View {
    let title: String
    let interval: String
    let keycap: String
    let isPrimary: Bool
    let isSubmitting: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isPrimary ? LunarTokens.neutralHighlight : .primary)
                    KeycapLabel(keycap)
                }
                Text(interval)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, LunarTokens.space2 + 2)
            .background(
                Color.primary.opacity(isHovered ? 0.08 : 0.04),
                in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    .strokeBorder(
                        isPrimary
                            ? Color.primary.opacity(0.32)
                            : LunarTokens.hairlineBorder(),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(QuietPressButtonStyle())
        .onHover { isHovered = $0 }
        .disabled(isSubmitting)
    }
}

private struct CompletionStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

private struct ShortcutRow: View {
    let action: String
    let keys: [String]

    var body: some View {
        HStack {
            Text(action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeycapLabel(key)
                }
            }
        }
    }
}
