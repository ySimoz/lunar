import SwiftUI

/// Calm grouped setup view for Gauntlet survival/mixed runs across selected decks.
public struct GauntletSetupView: View {
    @Bindable var libraryVM: LibraryViewModel
    @State private var setupVM: GauntletSetupViewModel
    @State private var showRecentRuns = false

    public let onStartGauntlet: (StudyLaunchRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        libraryVM: LibraryViewModel,
        onStartGauntlet: @escaping (StudyLaunchRequest) -> Void
    ) {
        self.libraryVM = libraryVM
        self.onStartGauntlet = onStartGauntlet
        _setupVM = State(initialValue: GauntletSetupViewModel(
            decks: libraryVM.decks,
            defaultLives: libraryVM.preferences.defaultLives
        ))
    }

    public var body: some View {
        let pooledCount = setupVM.pooledCardsCount(cardsByDeck: libraryVM.cardsByDeck)
        let effectiveCount = setupVM.effectiveRunCount(cardsByDeck: libraryVM.cardsByDeck)
        let recentRuns = GauntletSetupViewModel.recentGauntletRuns(from: libraryVM.sessions)

        HStack(alignment: .top, spacing: LunarTokens.space5) {
            deckSelectionCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: LunarTokens.space4) {
                headerCard(effectiveCount: effectiveCount, pooledCount: pooledCount)
                configurationCard
                recentRunsSection(recentRuns)
            }
            .frame(width: 400)
        }
        .padding(LunarTokens.space6)
        .frame(maxWidth: 1080, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Gauntlet")
        .onChange(of: libraryVM.decks) { _, updatedDecks in
            setupVM.syncDecks(updatedDecks)
        }
    }

    private func headerCard(effectiveCount: Int, pooledCount: Int) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Gauntlet")
                    .font(.system(size: 20, weight: .semibold))
                Text("Mixed recall across decks without altering spaced-repetition schedules.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Button {
                if let request = setupVM.buildLaunchRequest(
                    decks: libraryVM.decks,
                    cardsByDeck: libraryVM.cardsByDeck
                ) {
                    onStartGauntlet(request)
                }
            } label: {
                Text(effectiveCount > 0 ? "Start Gauntlet (\(effectiveCount))" : "Start Gauntlet")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonochromeProminentButtonStyle())
            .disabled(pooledCount == 0)
        }
        .padding(LunarTokens.space5)
        .lunarGlassCard(cornerRadius: LunarTokens.panelRadius)
    }

    private var deckSelectionCard: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack {
                Text("Decks")
                    .font(.system(size: 14, weight: .semibold))

                Text("\(setupVM.selectedDeckIDs.count) selected")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Select All") {
                    setupVM.selectAll(decks: libraryVM.decks)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LunarTokens.neutralHighlight)

                Button("Reset") {
                    setupVM.resetSelection()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if libraryVM.decks.isEmpty {
                Text("No decks available.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(libraryVM.decks.enumerated()), id: \.element.id) { index, deck in
                            let isSelected = setupVM.selectedDeckIDs.contains(deck.id)
                            let cardCount = libraryVM.cards(for: deck.id).count

                            Button {
                                setupVM.toggleDeck(deck.id)
                            } label: {
                                HStack(spacing: LunarTokens.space3) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(isSelected ? LunarTokens.neutralHighlight : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(deck.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(deck.category.rawValue)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text("\(cardCount) cards")
                                        .font(.system(size: 12))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, LunarTokens.space2 + 2)
                                .padding(.horizontal, LunarTokens.space2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < libraryVM.decks.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(LunarTokens.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Run Rules")
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                Text("Starting Lives")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                LunarSegmentedControl(
                    selection: $setupVM.livesChoice,
                    options: GauntletLivesChoice.allCases.map { ($0, $0.label) },
                    fullWidth: true
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                Text("Run Length")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                LunarSegmentedControl(
                    selection: $setupVM.runLength,
                    options: GauntletRunLength.allCases.map { ($0, $0.label) },
                    fullWidth: true
                )
            }
        }
        .padding(LunarTokens.space5)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    private func recentRunsSection(_ runs: [StudySessionRecord]) -> some View {
        DisclosureGroup("Recent Runs", isExpanded: $showRecentRuns) {
            if runs.isEmpty {
                Text("No Gauntlet runs recorded yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, LunarTokens.space2)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(runs.prefix(10).enumerated()), id: \.element.id) { idx, run in
                            let total = max(1, run.correctCount + run.incorrectCount)
                            let accuracy = Int((Double(run.correctCount) / Double(total) * 100.0).rounded())

                            HStack(spacing: LunarTokens.space3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(run.deckTitles.joined(separator: ", "))
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text(ISO8601DateFormatter.lunarShortDate(run.completedAt))
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(run.cardsReviewed) cards")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)

                                Text("\(accuracy)%")
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(LunarTokens.neutralHighlight)

                                if let lives = run.livesLeft {
                                    HStack(spacing: 3) {
                                        Image(systemName: lives > 0 ? "heart.fill" : "heart.slash")
                                            .font(.system(size: 11))
                                        Text("\(lives)")
                                            .font(.system(size: 12))
                                            .monospacedDigit()
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, LunarTokens.space2)

                            if idx < min(runs.count, 10) - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
                .padding(.top, LunarTokens.space2)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(LunarTokens.space5)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }
}
