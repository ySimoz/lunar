import Charts
import SwiftUI

/// Analytics dashboard with segmented `Overview | Cards` sub-views:
/// zero-scroll 2-column desktop Overview and full-height Card Inspector.
public struct AnalyticsView: View {
    private enum AnalyticsTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case cards = "Cards"
        var id: String { rawValue }
    }

    @Bindable var libraryVM: LibraryViewModel
    @State private var statsVM: StatsViewModel
    @State private var selectedTab: AnalyticsTab = .overview
    @State private var showInspector = false
    @State private var editingCard: Flashcard?
    @FocusState private var isCardSearchFocused: Bool

    private let client: (any CoreClientProtocol)?
    @Environment(\.colorScheme) private var colorScheme

    public init(libraryVM: LibraryViewModel, client: (any CoreClientProtocol)?) {
        self.libraryVM = libraryVM
        self.client = client
        _statsVM = State(initialValue: StatsViewModel(client: client))
    }

    private var selectedCard: Flashcard? {
        guard let id = statsVM.selectedCardID else { return nil }
        return libraryVM.allLoadedCards.first { $0.id == id }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            HStack(spacing: LunarTokens.space4) {
                LunarSegmentedControl(
                    selection: $selectedTab,
                    options: AnalyticsTab.allCases.map { ($0, $0.rawValue) }
                )

                if let error = statsVM.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }

                Spacer()
            }

            let summary = statsVM.summary ?? StatsSummary()

            if selectedTab == .overview {
                overviewContent(summary)
            } else {
                cardInspectorSection
            }
        }
        .padding(LunarTokens.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Analytics")
        .inspector(isPresented: $showInspector) {
            CardStatsInspector(
                card: selectedCard,
                fontFamily: libraryVM.preferences.fontFamily,
                fontSize: libraryVM.preferences.fontSize
            ) { card in
                editingCard = card
            }
            .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Toggle Card Inspector (⌘I)")
            }
        }
        .task(id: statsVM.daysWindow) {
            await statsVM.load()
        }
        .background {
            Button("") {
                if selectedTab == .cards {
                    isCardSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .sheet(item: $editingCard) { card in
            if let deck = libraryVM.deck(for: card.deckId) {
                CardEditorSheet(
                    deck: deck,
                    existingCard: card,
                    fontFamily: libraryVM.preferences.fontFamily,
                    fontSize: libraryVM.preferences.fontSize
                ) { updated in
                    Task {
                        if let client {
                            _ = try? await client.updateCard(id: updated.id, updated)
                            await libraryVM.loadAll()
                            await statsVM.load()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Overview Layout

    private func overviewContent(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            kpiStrip(summary)

            HStack(alignment: .top, spacing: LunarTokens.space4) {
                dailyTrendCard(summary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: LunarTokens.space4) {
                    memoryPipelineCard(summary.masteryPipeline, totalCards: summary.totalCards)
                    deckBreakdownCard(summary.deckBreakdown)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - 4-Cell KPI Strip

    private func kpiStrip(_ summary: StatsSummary) -> some View {
        HStack(spacing: 0) {
            KPIStripCell(
                label: "Retention",
                value: "\(summary.retentionRate)%",
                detail: "\(summary.totalCorrect) / \(summary.totalReviews) correct"
            )
            Divider().frame(height: 36)
            KPIStripCell(
                label: "Mastered",
                value: "\(summary.masteryPipeline.masteredCount)",
                detail: "\(summary.masteryPipeline.masteredPercent)% of \(summary.totalCards)"
            )
            Divider().frame(height: 36)
            KPIStripCell(
                label: "Reviews",
                value: "\(summary.totalReviews)",
                detail: "\(summary.dueCards) due now"
            )
            Divider().frame(height: 36)
            KPIStripCell(
                label: "Streak",
                value: "\(summary.currentStreakDays)d",
                detail: "Best \(summary.longestStreakDays)d",
                accentValue: summary.currentStreakDays > 0
            )
        }
        .padding(.vertical, LunarTokens.space4)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    // MARK: - Hero Swift Chart

    private func dailyTrendCard(_ summary: StatsSummary) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Activity")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Reviews completed over the last \(statsVM.daysWindow) days")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                LunarSegmentedControl(
                    selection: $statsVM.daysWindow,
                    options: [(14, "14d"), (30, "30d")]
                )
            }

            if summary.dailyActivity.allSatisfy({ $0.reviews == 0 }) {
                ContentUnavailableView(
                    "No Reviews in Window",
                    systemImage: "chart.bar",
                    description: Text("Complete study sessions to see your daily review cadence.")
                )
                .frame(height: 200)
            } else {
                Chart(summary.dailyActivity) { day in
                    if let date = day.parsedDate {
                        BarMark(
                            x: .value("Date", date, unit: .day),
                            y: .value("Reviews", day.reviews)
                        )
                        .foregroundStyle(LunarTokens.neutralHighlight)
                        .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: statsVM.daysWindow == 14 ? 2 : 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.06))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel()
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(LunarTokens.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lunarGlassCard(cornerRadius: LunarTokens.panelRadius)
    }

    // MARK: - Memory Pipeline

    private func memoryPipelineCard(_ pipeline: MasteryPipeline, totalCards: Int) -> some View {
        let total = max(1, totalCards)
        let masteredFrac = Double(pipeline.masteredCount) / Double(total)
        let reviewFrac = Double(pipeline.reviewCount) / Double(total)
        let learningFrac = Double(pipeline.learningCount) / Double(total)
        let newFrac = Double(pipeline.newCount) / Double(total)

        return VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack {
                Text("Memory Pipeline")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(totalCards) total")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                HStack(spacing: 2) {
                    if pipeline.masteredCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LunarTokens.neutralHighlight)
                            .frame(width: max(4, width * masteredFrac))
                    }
                    if pipeline.reviewCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: max(4, width * reviewFrac))
                    }
                    if pipeline.learningCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: max(4, width * learningFrac))
                    }
                    if pipeline.newCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.09))
                            .frame(width: max(4, width * newFrac))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 8)
            .background(LunarTokens.neutralTrack, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            HStack(spacing: LunarTokens.space5) {
                PipelineLegendItem(
                    label: "Mastered",
                    count: pipeline.masteredCount,
                    color: LunarTokens.neutralHighlight
                )
                PipelineLegendItem(
                    label: "Reviewing",
                    count: pipeline.reviewCount,
                    color: Color.primary.opacity(0.45)
                )
                PipelineLegendItem(
                    label: "Learning",
                    count: pipeline.learningCount,
                    color: Color.primary.opacity(0.22)
                )
                PipelineLegendItem(
                    label: "New",
                    count: pipeline.newCount,
                    color: Color.primary.opacity(0.09)
                )
                Spacer()
            }
        }
        .padding(LunarTokens.space5)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    // MARK: - Deck Breakdown

    private func deckBreakdownCard(_ rows: [DeckBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Deck Mastery")
                .font(.system(size: 14, weight: .semibold))

            if rows.isEmpty {
                Text("No decks available.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                            HStack(spacing: LunarTokens.space3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(row.masteredCards) / \(row.totalCards) mastered · \(row.dueCards) due")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 140, alignment: .leading)

                                Spacer()

                                Text("Ease \(String(format: "%.2f", row.averageEase))")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)

                                MasteryBar(progress: Double(row.masteredPercent) / 100.0)
                                    .frame(width: 90)

                                Text("\(row.masteredPercent)%")
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .padding(.vertical, LunarTokens.space2 + 2)

                            if idx < rows.count - 1 {
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

    // MARK: - Card Inspector Section

    private var cardInspectorSection: some View {
        let filtered = StatsViewModel.filterCards(
            libraryVM.allLoadedCards,
            filter: statsVM.inspectorFilter,
            query: statsVM.inspectorSearch
        )

        return VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack(spacing: LunarTokens.space3) {
                Text("Card Inspector")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                LunarSegmentedControl(
                    selection: $statsVM.inspectorFilter,
                    options: CardInspectorFilter.allCases.map { ($0, $0.rawValue) }
                )

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("", text: $statsVM.inspectorSearch, prompt: Text("Search cards"))
                        .accessibilityLabel("Filter cards")
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isCardSearchFocused)
                        .focusEffectDisabled()

                    if !statsVM.inspectorSearch.isEmpty {
                        Button {
                            statsVM.inspectorSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, LunarTokens.space2)
                .padding(.vertical, 5)
                .frame(width: 210)
                .background(
                    Color.primary.opacity(isCardSearchFocused ? 0.08 : 0.04),
                    in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                        .strokeBorder(
                            isCardSearchFocused ? Color.primary.opacity(0.28) : LunarTokens.hairlineBorder(),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    "No Matching Cards",
                    systemImage: "magnifyingglass",
                    description: Text("Adjust or clear the filter to inspect cards.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, card in
                            let isSelected = statsVM.selectedCardID == card.id
                            Button {
                                statsVM.selectedCardID = card.id
                                showInspector = true
                            } label: {
                                HStack(spacing: LunarTokens.space3) {
                                    CardTypeDot(card.cardType)

                                    Text(MathPlainText.format(card.front))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text(card.masteryStage.label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 68, alignment: .trailing)

                                    Text("Int \(card.formattedInterval)")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(card.isDue() ? LunarTokens.neutralHighlight : .secondary)
                                        .frame(width: 68, alignment: .trailing)

                                    Text("Ease \(String(format: "%.2f", card.easeFactor))")
                                        .font(.system(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(card.easeFactor < StatsViewModel.lowEaseThreshold ? .primary : .secondary)
                                        .frame(width: 72, alignment: .trailing)
                                }
                                .padding(.horizontal, LunarTokens.space3)
                                .padding(.vertical, LunarTokens.space2)
                                .background(
                                    isSelected ? Color.primary.opacity(0.06) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if idx < filtered.count - 1 {
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
}

private struct KPIStripCell: View {
    let label: String
    let value: String
    let detail: String
    var accentValue: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accentValue ? LunarTokens.neutralHighlight : .primary)
            Text(detail)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LunarTokens.space5)
    }
}

private struct PipelineLegendItem: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}
