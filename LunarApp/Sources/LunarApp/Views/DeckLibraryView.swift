import SwiftUI

/// Smart `Today` review hub combining summary metrics, crash recovery, `Study Due` CTA,
/// and a segmented `Due | All` glassmorphic deck grid (study-only; deck editing lives in `Library`).
public struct DeckLibraryView: View {
    @Bindable var libraryVM: LibraryViewModel
    public let onStartStudy: (StudyLaunchRequest) -> Void

    @State private var showOnlyDue: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.adaptive(minimum: 270, maximum: 380), spacing: LunarTokens.space4)
    ]

    public init(
        libraryVM: LibraryViewModel,
        onStartStudy: @escaping (StudyLaunchRequest) -> Void = { _ in }
    ) {
        self.libraryVM = libraryVM
        self.onStartStudy = onStartStudy
    }

    public var body: some View {
        let displayedDecks = showOnlyDue
            ? libraryVM.decks.filter { $0.dueCount > 0 }
            : libraryVM.decks

        ScrollView {
            VStack(alignment: .leading, spacing: LunarTokens.space5) {
                if let resume = libraryVM.resolveActiveSessionLaunch() {
                    crashRecoveryBanner(
                        deck: resume.deck,
                        cards: resume.cards,
                        state: resume.state
                    )
                }

                summaryStrip

                if !libraryVM.decks.isEmpty {
                    HStack {
                        LunarSegmentedControl(
                            selection: $showOnlyDue,
                            options: [
                                (false, "All"),
                                (true, "Due")
                            ]
                        )

                        Spacer()
                    }
                }

                if libraryVM.isLoading && libraryVM.decks.isEmpty {
                    ProgressView("Loading decks")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if displayedDecks.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: LunarTokens.space4) {
                        ForEach(displayedDecks) { deck in
                            let cards = libraryVM.cards(for: deck.id)
                            let dueCards = cards.filter { $0.isDue() }

                            DeckCardView(
                                deck: deck,
                                masteryRatio: libraryVM.masteryRatio(for: deck.id),
                                masteryPercent: libraryVM.masteryPercent(for: deck.id),
                                onOpen: {
                                    libraryVM.selection = .deck(deck.id)
                                },
                                onStudyDue: dueCards.isEmpty ? nil : {
                                    onStartStudy(StudyLaunchRequest(deck: deck, cards: dueCards, mode: .standard))
                                },
                                onStudyAll: cards.isEmpty ? nil : {
                                    onStartStudy(StudyLaunchRequest(deck: deck, cards: cards, mode: .standard))
                                }
                            )
                        }
                    }
                }
            }
            .padding(LunarTokens.space6)
        }
        .navigationTitle("Today")
    }

    private func crashRecoveryBanner(deck: Deck, cards: [Flashcard], state: ActiveSessionState) -> some View {
        HStack(spacing: LunarTokens.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(deck.title) — \(state.reviewedCardIds.count) of \(state.cardIds.count) reviewed")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Discard") {
                Task { await libraryVM.discardActiveSession() }
            }
            .buttonStyle(.bordered)

            Button("Resume") {
                let resolvedDeckTitles = state.deckIds.compactMap { id in
                    libraryVM.deck(for: id)?.title
                }
                onStartStudy(StudyLaunchRequest(
                    deck: deck,
                    cards: cards,
                    mode: state.mode,
                    startingLives: state.livesLeft,
                    deckIds: state.deckIds.isEmpty ? [deck.id] : state.deckIds,
                    deckTitles: resolvedDeckTitles.isEmpty ? [deck.title] : resolvedDeckTitles,
                    restoredState: state
                ))
            }
            .buttonStyle(MonochromeProminentButtonStyle())
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space3)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius, isSelected: true)
    }

    private var summaryStrip: some View {
        HStack(spacing: LunarTokens.space6) {
            SummaryStatItem(label: "Decks", value: "\(libraryVM.decks.count)")
            Divider().frame(height: 24)
            SummaryStatItem(label: "Total Cards", value: "\(libraryVM.totalCards)")
            Divider().frame(height: 24)
            SummaryStatItem(
                label: "Due Today",
                value: "\(libraryVM.totalDue)",
                highlight: libraryVM.totalDue > 0
            )
            Divider().frame(height: 24)
            SummaryStatItem(label: "Mastery", value: "\(libraryVM.overallMasteryPercent)%")
            Spacer()

            if let dueRequest = libraryVM.buildTodayDueStudyRequest() {
                Button {
                    onStartStudy(dueRequest)
                } label: {
                    Text("Study Due (\(dueRequest.cards.count))")
                        .monospacedDigit()
                }
                .buttonStyle(MonochromeProminentButtonStyle())
            }
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space3)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    @ViewBuilder
    private var emptyState: some View {
        if showOnlyDue {
            ContentUnavailableView(
                "Nothing Due Today",
                systemImage: "checkmark.circle",
                description: Text("All scheduled cards have been reviewed.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            ContentUnavailableView {
                Label("No Decks", systemImage: "square.stack.3d.up")
            } description: {
                Text("Create decks in Library to begin studying.")
            } actions: {
                Button("Open Library") {
                    libraryVM.selection = .library
                }
                .buttonStyle(MonochromeProminentButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }
}

private struct SummaryStatItem: View {
    let label: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ? LunarTokens.neutralHighlight : .primary)
        }
    }
}

/// Glassmorphic deck card with quiet metadata, optional chapter structure summary,
/// optional management actions, optional bounded drag reorder, and a single 4pt mastery bar.
public struct DeckCardView: View {
    public let deck: Deck
    public let masteryRatio: Double
    public let masteryPercent: Int
    public var structureSummary: String? = nil
    public let onOpen: () -> Void
    public var onEdit: (() -> Void)? = nil
    public var onDelete: (() -> Void)? = nil
    public var onRename: (() -> Void)? = nil
    public var onStudyDue: (() -> Void)? = nil
    public var onStudyAll: (() -> Void)? = nil
    public var onExport: (() -> Void)? = nil
    public var canDragToReorder: Bool = false
    public var isBeingDragged: Bool = false
    public var onDragChanged: ((CGPoint) -> Void)? = nil
    public var onDragEnded: (() -> Void)? = nil

    @State private var isHovered = false

    public init(
        deck: Deck,
        masteryRatio: Double,
        masteryPercent: Int,
        structureSummary: String? = nil,
        onOpen: @escaping () -> Void,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onRename: (() -> Void)? = nil,
        onStudyDue: (() -> Void)? = nil,
        onStudyAll: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil,
        canDragToReorder: Bool = false,
        isBeingDragged: Bool = false,
        onDragChanged: ((CGPoint) -> Void)? = nil,
        onDragEnded: (() -> Void)? = nil
    ) {
        self.deck = deck
        self.masteryRatio = masteryRatio
        self.masteryPercent = masteryPercent
        self.structureSummary = structureSummary
        self.onOpen = onOpen
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onRename = onRename
        self.onStudyDue = onStudyDue
        self.onStudyAll = onStudyAll
        self.onExport = onExport
        self.canDragToReorder = canDragToReorder
        self.isBeingDragged = isBeingDragged
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    private var hasManagementMenu: Bool {
        onRename != nil || onEdit != nil || onExport != nil || onDelete != nil
    }

    public var body: some View {
        let cardContent = VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack(spacing: LunarTokens.space2) {
                Button(action: handleOpenTap) {
                    HStack(spacing: LunarTokens.space2) {
                        Text(deck.category.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(deck.difficulty.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if hasManagementMenu {
                    Menu {
                        deckMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
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
                    .help("Deck Actions")
                }
            }

            Button(action: handleOpenTap) {
                VStack(alignment: .leading, spacing: LunarTokens.space3) {
                    VStack(alignment: .leading, spacing: LunarTokens.space1) {
                        Text(deck.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(deck.description.isEmpty ? "No description" : deck.description)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(minHeight: 34, alignment: .topLeading)
                    }

                    if let structureSummary {
                        Text(structureSummary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    VStack(alignment: .leading, spacing: LunarTokens.space2) {
                        HStack(spacing: LunarTokens.space2) {
                            MasteryBar(progress: masteryRatio)
                            Text("\(masteryPercent)%")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: LunarTokens.space3) {
                            Text("\(deck.cardCount) cards")
                                .font(.system(size: 12, weight: .regular))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

                            Spacer()

                            if deck.dueCount > 0 {
                                Text("\(deck.dueCount) due")
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(LunarTokens.neutralHighlight)
                            } else {
                                Text("Caught up")
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietPressButtonStyle())
        }
        .padding(LunarTokens.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius, isHovered: isHovered)
        .opacity(isBeingDragged ? 0.25 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            deckMenuContent
        }

        if canDragToReorder, let onDragChanged, let onDragEnded {
            cardContent
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .global)
                        .onChanged { value in
                            onDragChanged(value.location)
                        }
                        .onEnded { _ in
                            onDragEnded()
                        }
                )
        } else {
            cardContent
        }
    }

    private func handleOpenTap() {
        guard !isBeingDragged else { return }
        onOpen()
    }

    @ViewBuilder
    private var deckMenuContent: some View {
        Button("Open Deck", action: onOpen)

        if let onStudyDue, deck.dueCount > 0 {
            Button("Study Due (\(deck.dueCount))", action: onStudyDue)
        }
        if let onStudyAll, deck.cardCount > 0 {
            Button("Study All", action: onStudyAll)
        }

        if hasManagementMenu {
            Divider()

            if let onRename {
                Button("Rename Deck", action: onRename)
            }
            if let onEdit {
                Button("Edit Details & Chapters", action: onEdit)
            }

            if let onExport {
                Divider()
                Button("Export", action: onExport)
            }

            if let onDelete {
                Divider()
                Button("Delete Deck", role: .destructive, action: onDelete)
            }
        }
    }
}
