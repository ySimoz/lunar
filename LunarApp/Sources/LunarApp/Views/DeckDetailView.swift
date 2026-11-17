import SwiftUI

/// Detailed view for a single deck: study header, filters, collapsible chapter groups,
/// drag reorder, multi-select floating bar, and optional right-hand card stats inspector (`⌘I`).
public struct DeckDetailView: View {
    public let deck: Deck
    @Bindable var libraryVM: LibraryViewModel
    @State private var detailVM: DeckDetailViewModel
    @State private var showInspector = false
    @State private var isSearchPresented = false
    @State private var editingCard: Flashcard?
    @State private var isCreatingCard = false
    @State private var newCardInitialTopic: String?
    @State private var cardPendingDelete: Flashcard?
    @State private var isConfirmingBulkDelete = false
    @State private var isConfirmingDeckDelete = false
    @State private var transferSheetCards: [Flashcard]?
    @State private var showNewChapterPopover = false
    @State private var newChapterTitle = ""
    @State private var chapterPendingRename: ChapterRenameItem?
    @State private var chapterPendingDelete: ChapterGroup?

    public let onEditDeck: (Deck) -> Void
    public let onStartStudy: (StudyLaunchRequest) -> Void

    public init(
        deck: Deck,
        libraryVM: LibraryViewModel,
        client: (any CoreClientProtocol)?,
        onEditDeck: @escaping (Deck) -> Void,
        onStartStudy: @escaping (StudyLaunchRequest) -> Void
    ) {
        self.deck = deck
        self.libraryVM = libraryVM
        self.onEditDeck = onEditDeck
        self.onStartStudy = onStartStudy
        let initialCards = libraryVM.cards(for: deck.id)
        _detailVM = State(initialValue: DeckDetailViewModel(
            deck: deck,
            initialCards: initialCards,
            client: client
        ))
    }

    public var body: some View {
        withDialogs(withSheets(withLifecycleAndToolbar(splitContent)))
    }

    private var splitContent: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    deckHeader
                        .padding(.horizontal, LunarTokens.space6)
                        .padding(.top, LunarTokens.space5)
                        .padding(.bottom, LunarTokens.space4)

                    filterBar
                        .padding(.horizontal, LunarTokens.space6)
                        .padding(.bottom, LunarTokens.space3)

                    chapterList
                }

                if detailVM.isMultiSelectMode {
                    multiSelectFloatingBar
                        .padding(.horizontal, LunarTokens.space6)
                        .padding(.bottom, LunarTokens.space5)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if showInspector {
                Rectangle()
                    .fill(LunarTokens.hairlineBorder())
                    .frame(width: 1)

                CardStatsInspector(
                    card: detailVM.selectedCard,
                    fontFamily: libraryVM.preferences.fontFamily,
                    fontSize: libraryVM.preferences.fontSize,
                    isEditDisabled: detailVM.isMultiSelectMode
                ) { card in
                    guard !detailVM.isMultiSelectMode else { return }
                    editingCard = card
                }
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(LunarTokens.revealAnimation, value: detailVM.isMultiSelectMode)
        .animation(LunarTokens.revealAnimation, value: showInspector)
    }

    private func withLifecycleAndToolbar<Content: View>(_ content: Content) -> some View {
        content
            .navigationTitle(detailVM.deck.title)
            .searchable(
                text: $detailVM.searchQuery,
                isPresented: $isSearchPresented,
                placement: .lunarToolbar,
                prompt: "Search cards"
            )
            .background {
                Button("") {
                    isSearchPresented = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Edit Deck") {
                            onEditDeck(detailVM.deck)
                        }
                        Divider()
                        Button("Import") {
                            libraryVM.requestedImportExportTab = .import
                        }
                        Button("Export") {
                            libraryVM.requestedImportExportDeckId = detailVM.deck.id
                            libraryVM.requestedImportExportTab = .export
                        }
                        Divider()
                        Button("Delete Deck", role: .destructive) {
                            isConfirmingDeckDelete = true
                        }
                    } label: {
                        Label("Deck Actions", systemImage: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .disabled(detailVM.isMultiSelectMode)
                    .help("Deck Actions")

                    Button {
                        withAnimation(LunarTokens.revealAnimation) {
                            showInspector.toggle()
                        }
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(detailVM.isMultiSelectMode)
                    .help("Toggle Card Inspector (⌘I)")
                }
            }
            .onChange(of: deck.id) { _, _ in
                libraryVM.dragCoordinator.resetDeckDetailFrames()
                detailVM.sync(deck: deck, cards: libraryVM.cards(for: deck.id))
            }
            .onDisappear {
                libraryVM.dragCoordinator.resetDeckDetailFrames()
                libraryVM.dragCoordinator.endDrag()
            }
            .task(id: deck.id) {
                await detailVM.loadCards()
                if detailVM.deck.id == deck.id {
                    libraryVM.syncCards(detailVM.cards, for: deck.id)
                }
            }
            .onChange(of: libraryVM.decks) { _, updatedDecks in
                if let latest = updatedDecks.first(where: { $0.id == deck.id }) {
                    detailVM.deck = latest
                }
            }
            .onChange(of: libraryVM.cardsByDeck[deck.id]) { _, updatedCards in
                if let updatedCards, detailVM.deck.id == deck.id {
                    detailVM.cards = updatedCards.sorted { $0.order < $1.order }
                }
            }
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $isCreatingCard) {
            CardEditorSheet(
                deck: detailVM.deck,
                initialTopic: newCardInitialTopic,
                fontFamily: libraryVM.preferences.fontFamily,
                fontSize: libraryVM.preferences.fontSize
            ) { draft in
                Task {
                    if await detailVM.saveCard(draft, isNew: true) != nil {
                        libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                        await libraryVM.refreshDecks()
                    }
                }
            }
        }
        .sheet(item: $editingCard) { card in
            CardEditorSheet(
                deck: detailVM.deck,
                existingCard: card,
                fontFamily: libraryVM.preferences.fontFamily,
                fontSize: libraryVM.preferences.fontSize
            ) { draft in
                Task {
                    if await detailVM.saveCard(draft, isNew: false) != nil {
                        libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                        await libraryVM.refreshDecks()
                    }
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { transferSheetCards != nil },
                set: { if !$0 { transferSheetCards = nil } }
            )
        ) {
            if let cardsToMove = transferSheetCards {
                TransferCardsSheet(
                    cards: cardsToMove,
                    sourceDeckId: detailVM.deck.id,
                    decks: libraryVM.decks
                ) { targetDeckId, targetTopic in
                    await detailVM.transferCards(
                        cardIds: cardsToMove.map(\.id),
                        targetDeckId: targetDeckId,
                        targetTopic: targetTopic
                    )
                    await libraryVM.loadAll()
                }
            }
        }
        .sheet(item: $chapterPendingRename) { item in
            RenameChapterSheet(
                currentTitle: item.title,
                existingChapters: detailVM.deck.chapters
            ) { updatedTitle in
                Task {
                    if await detailVM.renameChapter(old: item.title, new: updatedTitle) {
                        libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                        await libraryVM.refreshDecks()
                    }
                }
            }
        }
    }

    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .confirmationDialog(
            "Delete Chapter",
            isPresented: Binding(
                get: { chapterPendingDelete != nil },
                set: { if !$0 { chapterPendingDelete = nil } }
            ),
            presenting: chapterPendingDelete
        ) { group in
            if group.cards.isEmpty {
                Button("Delete Chapter", role: .destructive) {
                    Task {
                        if await detailVM.deleteChapter(group.title, deleteCards: false) {
                            await libraryVM.refreshDecks()
                        }
                    }
                }
            } else {
                Button("Move Cards to General") {
                    Task {
                        if await detailVM.deleteChapter(group.title, deleteCards: false) {
                            libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                            await libraryVM.refreshDecks()
                        }
                    }
                }
                Button("Delete Chapter & \(group.cards.count) Cards", role: .destructive) {
                    Task {
                        if await detailVM.deleteChapter(group.title, deleteCards: true) {
                            libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                            await libraryVM.refreshDecks()
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            Text(
                group.cards.isEmpty
                    ? "Remove \"\(group.title)\" from this deck."
                    : "Choose whether to move \(group.cards.count) cards in \"\(group.title)\" to General or delete them."
            )
        }
        .confirmationDialog(
            "Delete Card",
            isPresented: Binding(
                get: { cardPendingDelete != nil },
                set: { if !$0 { cardPendingDelete = nil } }
            ),
            presenting: cardPendingDelete
        ) { card in
            Button("Delete Card", role: .destructive) {
                Task {
                    await detailVM.deleteCard(id: card.id)
                    libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                    await libraryVM.refreshDecks()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the card and its review history. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete Selected Cards",
            isPresented: $isConfirmingBulkDelete
        ) {
            Button("Delete \(detailVM.selectedCardIDs.count) Cards", role: .destructive) {
                Task {
                    await detailVM.deleteSelectedCards()
                    libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                    await libraryVM.refreshDecks()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected cards and their review history.")
        }
        .confirmationDialog(
            "Delete Deck",
            isPresented: $isConfirmingDeckDelete
        ) {
            Button("Delete \"\(detailVM.deck.title)\"", role: .destructive) {
                Task {
                    await libraryVM.deleteDeck(id: detailVM.deck.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \"\(detailVM.deck.title)\" and all of its cards.")
        }
    }

    // MARK: - Deck Header

    private var deckHeader: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack(alignment: .top, spacing: LunarTokens.space4) {
                VStack(alignment: .leading, spacing: LunarTokens.space1) {
                    HStack(spacing: LunarTokens.space2) {
                        Text(detailVM.deck.category.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text(detailVM.deck.difficulty.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(detailVM.deck.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)

                    if !detailVM.deck.description.isEmpty {
                        Text(detailVM.deck.description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: LunarTokens.space4)

                HStack(spacing: LunarTokens.space2) {
                    Button("Study All") {
                        onStartStudy(StudyLaunchRequest(
                            deck: detailVM.deck,
                            cards: detailVM.cards,
                            mode: .standard
                        ))
                    }
                    .buttonStyle(MonochromeGlassButtonStyle())
                    .disabled(detailVM.isMultiSelectMode || detailVM.cards.isEmpty)

                    Button {
                        let dueCards = detailVM.cards.filter { $0.isDue() }
                        onStartStudy(StudyLaunchRequest(
                            deck: detailVM.deck,
                            cards: dueCards,
                            mode: .standard
                        ))
                    } label: {
                        Text("Review Due (\(detailVM.dueCardsCount))")
                            .monospacedDigit()
                    }
                    .buttonStyle(MonochromeProminentButtonStyle())
                    .disabled(detailVM.isMultiSelectMode || detailVM.dueCardsCount == 0)
                }
            }

            HStack(spacing: LunarTokens.space4) {
                HStack(spacing: LunarTokens.space2) {
                    MasteryBar(progress: Double(detailVM.masteryPercent) / 100.0)
                        .frame(width: 120)
                    Text("\(detailVM.masteryPercent)% mastered")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(detailVM.cards.count) cards")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Text("\(detailVM.dueCardsCount) due")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(
                        detailVM.dueCardsCount > 0
                            ? LunarTokens.neutralHighlight
                            : .secondary
                    )
            }
        }
        .padding(LunarTokens.space5)
        .lunarGlassCard(cornerRadius: LunarTokens.panelRadius)
    }

    // MARK: - Filter & Action Bar

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LunarTokens.space3) {
                filterControls
                Spacer(minLength: LunarTokens.space2)
                actionControls
            }

            VStack(alignment: .leading, spacing: LunarTokens.space2) {
                HStack(spacing: LunarTokens.space3) {
                    filterControls
                    Spacer()
                }
                HStack(spacing: LunarTokens.space2) {
                    Spacer()
                    actionControls
                }
            }
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        LunarMenuPicker(
            selection: $detailVM.filterType,
            options: [(CardType?.none, "All Types")] + CardType.allCases.map { (CardType?.some($0), $0.displayName) }
        )
        .disabled(detailVM.isMultiSelectMode)

        LunarMenuPicker(
            selection: $detailVM.filterDifficulty,
            options: [(Difficulty?.none, "All Levels")] + Difficulty.allCases.map { (Difficulty?.some($0), $0.displayName) }
        )
        .disabled(detailVM.isMultiSelectMode)

        Toggle("Due only", isOn: $detailVM.dueOnly)
            .toggleStyle(MonochromeGlassToggleStyle(compact: true, expandRow: false))
            .font(.system(size: 12, weight: .medium))
            .disabled(detailVM.isMultiSelectMode)

        if detailVM.hasActiveFilters {
            Button("Clear") {
                detailVM.clearFilters()
            }
            .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            .disabled(detailVM.isMultiSelectMode)
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        Button("New Card") {
            newCardInitialTopic = nil
            isCreatingCard = true
        }
        .buttonStyle(MonochromeProminentButtonStyle(compact: true))
        .disabled(detailVM.isMultiSelectMode)

        Button("New Chapter") {
            newChapterTitle = ""
            showNewChapterPopover = true
        }
        .buttonStyle(MonochromeGlassButtonStyle(compact: true))
        .disabled(detailVM.isMultiSelectMode)
        .popover(isPresented: $showNewChapterPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: LunarTokens.space3) {
                Text("New Chapter")
                    .font(.system(size: 13, weight: .semibold))
                TextField("", text: $newChapterTitle, prompt: Text("Chapter name"))
                    .accessibilityLabel("Chapter name")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { submitNewChapter() }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        showNewChapterPopover = false
                    }
                    Button("Add") {
                        submitNewChapter()
                    }
                    .buttonStyle(MonochromeProminentButtonStyle(compact: true))
                    .disabled(newChapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(LunarTokens.space4)
        }

        Button(detailVM.isMultiSelectMode ? "Done" : "Select") {
            detailVM.toggleMultiSelect()
        }
        .buttonStyle(MonochromeGlassButtonStyle(compact: true))
    }

    // MARK: - Chapter List (Fast ScrollView + LazyVStack, 0ms selection & expand/collapse)

    @ViewBuilder
    private var chapterList: some View {
        let groups = detailVM.chapterGroups

        if detailVM.isLoading && detailVM.cards.isEmpty && libraryVM.cardsByDeck[deck.id] == nil {
            ProgressView("Loading cards")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            ContentUnavailableView {
                Label(
                    detailVM.hasActiveFilters ? "No Matching Cards" : "No Cards Yet",
                    systemImage: detailVM.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "rectangle.on.rectangle"
                )
            } description: {
                Text(
                    detailVM.hasActiveFilters
                        ? "Adjust or clear filters to see cards in this deck."
                        : "Add a card to start building this deck."
                )
            } actions: {
                if detailVM.hasActiveFilters {
                    Button("Clear Filters") { detailVM.clearFilters() }
                } else {
                    Button("New Card") { isCreatingCard = true }
                        .buttonStyle(MonochromeProminentButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LunarTokens.space4) {
                    ForEach(groups) { group in
                        let isExpanded = detailVM.isChapterExpanded(group.title)
                        let isChapterDropTarget = libraryVM.dragCoordinator.hoveredChapter == group.title

                        VStack(alignment: .leading, spacing: LunarTokens.space2) {
                            chapterHeader(for: group, isExpanded: isExpanded)

                            if isExpanded {
                                if group.cards.isEmpty {
                                    HStack(spacing: LunarTokens.space3) {
                                        Text("No cards in this chapter")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Add Card") {
                                            newCardInitialTopic = group.title == DeckDetailViewModel.uncategorizedChapterTitle ? "" : group.title
                                            isCreatingCard = true
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(detailVM.isMultiSelectMode ? Color.secondary.opacity(0.45) : LunarTokens.neutralHighlight)
                                        .disabled(detailVM.isMultiSelectMode)
                                    }
                                    .padding(.vertical, LunarTokens.space2)
                                    .padding(.horizontal, LunarTokens.space3)
                                } else {
                                    ForEach(Array(group.cards.enumerated()), id: \.element.id) { idx, card in
                                        if libraryVM.dragCoordinator.hoveredChapter == group.title,
                                           libraryVM.dragCoordinator.hoveredInsertIndex == idx,
                                           libraryVM.dragCoordinator.draggingCard?.id != card.id {
                                            Capsule()
                                                .fill(LunarTokens.neutralHighlight)
                                                .frame(height: 2)
                                                .padding(.horizontal, LunarTokens.space2)
                                        }

                                        cardRow(for: card, index: idx, in: group)

                                        if idx == group.cards.count - 1,
                                           libraryVM.dragCoordinator.hoveredChapter == group.title,
                                           libraryVM.dragCoordinator.hoveredInsertIndex == group.cards.count,
                                           libraryVM.dragCoordinator.draggingCard?.id != card.id {
                                            Capsule()
                                                .fill(LunarTokens.neutralHighlight)
                                                .frame(height: 2)
                                                .padding(.horizontal, LunarTokens.space2)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(LunarTokens.space2)
                        .background {
                            if isChapterDropTarget {
                                RoundedRectangle(cornerRadius: LunarTokens.cardRadius, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            }
                        }
                        .overlay {
                            if isChapterDropTarget {
                                RoundedRectangle(cornerRadius: LunarTokens.cardRadius, style: .continuous)
                                    .strokeBorder(LunarTokens.neutralHighlight.opacity(0.55), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .reportWindowFrame { rect in
                            libraryVM.dragCoordinator.chapterFrames[group.title] = rect
                        }
                    }

                    if let dragged = libraryVM.dragCoordinator.draggingCard,
                       !dragged.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !groups.contains(where: { $0.title == DeckDetailViewModel.uncategorizedChapterTitle }) {
                        let isGeneralDrop = libraryVM.dragCoordinator.hoveredChapter == DeckDetailViewModel.uncategorizedChapterTitle
                        HStack {
                            Text("Drop here to move outside chapters (\(DeckDetailViewModel.uncategorizedChapterTitle))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isGeneralDrop ? .primary : .secondary)
                            Spacer()
                        }
                        .padding(.horizontal, LunarTokens.space4)
                        .padding(.vertical, LunarTokens.space3)
                        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius, isSelected: isGeneralDrop)
                        .reportWindowFrame { rect in
                            libraryVM.dragCoordinator.chapterFrames[DeckDetailViewModel.uncategorizedChapterTitle] = rect
                        }
                    }
                }
                .padding(.horizontal, LunarTokens.space6)
                .padding(.top, LunarTokens.space1)
                .padding(.bottom, detailVM.isMultiSelectMode ? 80 : 24)
            }
        }
    }

    private func chapterHeader(for group: ChapterGroup, isExpanded: Bool) -> some View {
        HStack(spacing: LunarTokens.space2) {
            Button {
                detailVM.setChapter(group.title, expanded: !isExpanded)
            } label: {
                HStack(spacing: LunarTokens.space2) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("\(group.cards.count)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button("Study") {
                onStartStudy(StudyLaunchRequest(
                    deck: detailVM.deck,
                    cards: group.cards,
                    mode: .standard
                ))
            }
            .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            .disabled(detailVM.isMultiSelectMode || group.cards.isEmpty)

            Menu {
                chapterMenuItems(for: group)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LunarTokens.controlRadius, style: .continuous)
                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(detailVM.isMultiSelectMode)
            .opacity(detailVM.isMultiSelectMode ? 0.45 : 1.0)
            .help("Chapter Actions")
        }
        .padding(.vertical, LunarTokens.space1)
        .contextMenu {
            if !detailVM.isMultiSelectMode {
                chapterMenuItems(for: group)
            }
        }
    }

    @ViewBuilder
    private func cardRow(for card: Flashcard, index: Int, in group: ChapterGroup) -> some View {
        let isSelectedCard = detailVM.selectedCardID == card.id
        let canDragCard = isSelectedCard && !detailVM.isMultiSelectMode && detailVM.canReorderCards
        let isDraggingThis = libraryVM.dragCoordinator.draggingCard?.id == card.id

        CardRowView(
            card: card,
            isSelected: isSelectedCard,
            isMultiSelectMode: detailVM.isMultiSelectMode,
            isChecked: detailVM.selectedCardIDs.contains(card.id),
            isBeingDragged: isDraggingThis,
            canDragToMove: canDragCard,
            onSelect: {
                if detailVM.isMultiSelectMode {
                    detailVM.toggleCardSelection(card.id)
                } else {
                    detailVM.selectedCardID = card.id
                }
            },
            onEdit: {
                editingCard = card
            },
            onDragChanged: { fallbackLocation in
                let windowPt = LunarWindowCoordinates.currentPointerLocation() ?? fallbackLocation
                libraryVM.dragCoordinator.updateDrag(card: card, rawLocation: windowPt)
            },
            onDragEnded: {
                handleCardDrop(card)
            }
        )
        .reportWindowFrame { rect in
            libraryVM.dragCoordinator.cardFrames[card.id] = (chapter: group.title, index: index, rect: rect)
        }
        .onDisappear {
            libraryVM.dragCoordinator.cardFrames.removeValue(forKey: card.id)
        }
        .contextMenu {
            if detailVM.isMultiSelectMode {
                Button(detailVM.selectedCardIDs.contains(card.id) ? "Deselect Card" : "Select Card") {
                    detailVM.toggleCardSelection(card.id)
                }
                if !detailVM.selectedCardIDs.isEmpty {
                    Button("Deselect All") {
                        detailVM.selectedCardIDs.removeAll()
                    }
                }
                Divider()
                Button("Done Selecting") {
                    detailVM.toggleMultiSelect()
                }
            } else {
                Button("Inspect Stats") {
                    detailVM.selectedCardID = card.id
                    showInspector = true
                }
                Button("Edit Card") {
                    editingCard = card
                }
                Button("Move to") {
                    transferSheetCards = [card]
                }
                if detailVM.canReorderCards && group.cards.count > 1 {
                    Divider()
                    if index > 0 {
                        Button("Move Up") {
                            Task {
                                await detailVM.moveCards(
                                    inChapter: group.title,
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: index - 1
                                )
                                libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                            }
                        }
                    }
                    if index + 1 < group.cards.count {
                        Button("Move Down") {
                            Task {
                                await detailVM.moveCards(
                                    inChapter: group.title,
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: index + 2
                                )
                                libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete Card", role: .destructive) {
                    cardPendingDelete = card
                }
            }
        }
    }

    // MARK: - Multi-select Floating Bar

    private var multiSelectFloatingBar: some View {
        let hasSelection = !detailVM.selectedCardIDs.isEmpty

        return HStack(spacing: LunarTokens.space3) {
            Text("\(detailVM.selectedCardIDs.count) selected")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Divider().frame(height: 18)

            if hasSelection {
                Button("Deselect") {
                    detailVM.selectedCardIDs.removeAll()
                }
                .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            }

            Button("Study") {
                let selected = detailVM.cards.filter { detailVM.selectedCardIDs.contains($0.id) }
                guard !selected.isEmpty else { return }
                detailVM.toggleMultiSelect()
                onStartStudy(StudyLaunchRequest(
                    deck: detailVM.deck,
                    cards: selected,
                    mode: .standard
                ))
            }
            .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            .disabled(!hasSelection)

            Button("Move") {
                let selected = detailVM.cards.filter { detailVM.selectedCardIDs.contains($0.id) }
                guard !selected.isEmpty else { return }
                transferSheetCards = selected
            }
            .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            .disabled(!hasSelection)

            Button("Delete", role: .destructive) {
                isConfirmingBulkDelete = true
            }
            .disabled(!hasSelection)

            Button("Done") {
                detailVM.toggleMultiSelect()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(MonochromeProminentButtonStyle(compact: true))
        }
        .padding(.horizontal, LunarTokens.space4)
        .padding(.vertical, LunarTokens.space3)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    // MARK: - Chapter Helpers

    @ViewBuilder
    private func chapterMenuItems(for group: ChapterGroup) -> some View {
        let dueCards = group.cards.filter { $0.isDue() }

        Button("Study All") {
            onStartStudy(StudyLaunchRequest(
                deck: detailVM.deck,
                cards: group.cards,
                mode: .standard
            ))
        }
        .disabled(group.cards.isEmpty)

        Button("Study Due (\(dueCards.count))") {
            onStartStudy(StudyLaunchRequest(
                deck: detailVM.deck,
                cards: dueCards,
                mode: .standard
            ))
        }
        .disabled(dueCards.isEmpty)

        Button("New Card in Chapter") {
            newCardInitialTopic = group.title == DeckDetailViewModel.uncategorizedChapterTitle ? "" : group.title
            isCreatingCard = true
        }

        if group.title != DeckDetailViewModel.uncategorizedChapterTitle {
            Divider()

            Button("Rename Chapter") {
                chapterPendingRename = ChapterRenameItem(title: group.title)
            }

            Button("Delete Chapter", role: .destructive) {
                chapterPendingDelete = group
            }
        }
    }

    private func handleCardDrop(_ card: Flashcard) {
        let coordinator = libraryVM.dragCoordinator
        let targetDeckId = coordinator.hoveredDeckId
        let targetChapter = coordinator.hoveredChapter
        let targetInsertIndex = coordinator.hoveredInsertIndex
        coordinator.endDrag()

        if let targetDeckId, targetDeckId != card.deckId {
            Task {
                await detailVM.transferCards(
                    cardIds: [card.id],
                    targetDeckId: targetDeckId,
                    targetTopic: nil,
                    targetIndex: nil
                )
                await libraryVM.loadAll()
            }
            return
        }

        if let targetChapter {
            let normalizedTopic = targetChapter == DeckDetailViewModel.uncategorizedChapterTitle ? "" : targetChapter
            let currentTopic = card.topic.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedTopic == currentTopic,
               let targetInsertIndex,
               let group = detailVM.chapterGroups.first(where: { $0.title == targetChapter }),
               let sourceIdx = group.cards.firstIndex(where: { $0.id == card.id }) {
                let clampedDest = min(max(targetInsertIndex, 0), group.cards.count)
                guard clampedDest != sourceIdx && clampedDest != sourceIdx + 1 else { return }
                Task {
                    await detailVM.moveCards(
                        inChapter: targetChapter,
                        fromOffsets: IndexSet(integer: sourceIdx),
                        toOffset: clampedDest
                    )
                    libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                }
                return
            }

            if normalizedTopic != currentTopic {
                Task {
                    await detailVM.transferCards(
                        cardIds: [card.id],
                        targetDeckId: detailVM.deck.id,
                        targetTopic: normalizedTopic,
                        targetIndex: targetInsertIndex
                    )
                    libraryVM.syncCards(detailVM.cards, for: detailVM.deck.id)
                    await libraryVM.refreshDecks()
                }
            }
        }
    }

    private func submitNewChapter() {
        let candidate = newChapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        showNewChapterPopover = false
        newChapterTitle = ""
        Task {
            if await detailVM.addChapter(candidate) {
                await libraryVM.refreshDecks()
            }
        }
    }
}

private struct ChapterRenameItem: Identifiable {
    let id: String
    let title: String

    init(title: String) {
        self.id = title
        self.title = title
    }
}

private struct RenameChapterSheet: View {
    let currentTitle: String
    let existingChapters: [String]
    let onRename: (String) -> Void

    @State private var draftTitle: String
    @Environment(\.dismiss) private var dismiss

    init(currentTitle: String, existingChapters: [String], onRename: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.existingChapters = existingChapters
        self.onRename = onRename
        _draftTitle = State(initialValue: currentTitle)
    }

    private var trimmedDraft: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedDraft.isEmpty
            && trimmedDraft != currentTitle
            && trimmedDraft != DeckDetailViewModel.uncategorizedChapterTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            Text("Rename Chapter")
                .font(.system(size: 16, weight: .semibold))

            TextField("Chapter name", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if canSave {
                        onRename(trimmedDraft)
                        dismiss()
                    }
                }

            if existingChapters.contains(trimmedDraft) && trimmedDraft != currentTitle {
                Text("Cards will be merged into existing chapter \"\(trimmedDraft)\".")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onRename(trimmedDraft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MonochromeProminentButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(LunarTokens.space5)
        .frame(width: 360)
    }
}

private struct CardRowView: View {
    let card: Flashcard
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let isChecked: Bool
    let isBeingDragged: Bool
    let canDragToMove: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: LunarTokens.space2) {
            let mainButton = Button(action: onSelect) {
                HStack(spacing: LunarTokens.space3) {
                    if isMultiSelectMode {
                        Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(isChecked ? LunarTokens.neutralHighlight : .secondary)
                    }

                    CardTypeDot(card.cardType)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(MathPlainText.format(card.front))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        HStack(spacing: LunarTokens.space2) {
                            Text(card.cardType?.displayName ?? "Card")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(card.difficulty.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            if !card.layers.isEmpty {
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(card.layers.count == 1 ? "1 step" : "\(card.layers.count) steps")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: LunarTokens.space3)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(card.isDue() ? "Due" : card.formattedInterval)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(card.isDue() ? LunarTokens.neutralHighlight : .secondary)

                        Text(card.masteryStage.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canDragToMove {
                mainButton
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .global)
                            .onChanged { value in
                                onDragChanged(value.location)
                            }
                            .onEnded { _ in
                                onDragEnded()
                            }
                    )
            } else {
                mainButton
            }

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        Color.primary.opacity(isHovered && !isMultiSelectMode ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isMultiSelectMode)
            .opacity(isMultiSelectMode ? 0.22 : (isHovered || isSelected ? 1.0 : 0.55))
            .help(isMultiSelectMode ? "Finish selection to edit" : "Edit Card")
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2 + 2)
        .lunarGlassCard(
            cornerRadius: LunarTokens.controlRadius,
            isSelected: isSelected || (isMultiSelectMode && isChecked),
            isHovered: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .opacity(isBeingDragged ? 0.35 : 1.0)
    }
}
