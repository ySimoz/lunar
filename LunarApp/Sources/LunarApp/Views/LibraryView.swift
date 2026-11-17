import SwiftUI

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case custom
    case title
    case due
    case cards
    case mastery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .custom: "Custom Order"
        case .title: "Title"
        case .due: "Most Due"
        case .cards: "Most Cards"
        case .mastery: "Mastery"
        }
    }
}

/// Full deck management grid for browsing deck structures, creating, renaming,
/// reordering, importing, exporting, and deleting decks.
public struct LibraryView: View {
    @Bindable var libraryVM: LibraryViewModel
    public let onNewDeck: () -> Void
    public let onEditDeck: (Deck) -> Void
    public let onStartStudy: (StudyLaunchRequest) -> Void

    @State private var selectedCategory: SubjectCategory?
    @State private var sortOrder: LibrarySortOrder = .custom
    @State private var deckPendingRename: Deck?
    @State private var deckPendingDelete: Deck?
    @State private var isSearchPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 270, maximum: 380), spacing: LunarTokens.space4)
    ]

    public init(
        libraryVM: LibraryViewModel,
        onNewDeck: @escaping () -> Void,
        onEditDeck: @escaping (Deck) -> Void,
        onStartStudy: @escaping (StudyLaunchRequest) -> Void
    ) {
        self.libraryVM = libraryVM
        self.onNewDeck = onNewDeck
        self.onEditDeck = onEditDeck
        self.onStartStudy = onStartStudy
    }

    private var canReorder: Bool {
        sortOrder == .custom
            && selectedCategory == nil
            && libraryVM.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedDecks: [Deck] {
        var filtered = libraryVM.filteredDecks(onlyDue: false)
        if let selectedCategory {
            filtered = filtered.filter { $0.category == selectedCategory }
        }
        switch sortOrder {
        case .custom:
            if canReorder && !libraryVM.deckDragCoordinator.orderedDeckIds.isEmpty {
                let byId = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
                return libraryVM.deckDragCoordinator.orderedDeckIds.compactMap { byId[$0] }
            }
            return filtered
        case .title:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .due:
            return filtered.sorted { lhs, rhs in
                if lhs.dueCount != rhs.dueCount { return lhs.dueCount > rhs.dueCount }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .cards:
            return filtered.sorted { lhs, rhs in
                if lhs.cardCount != rhs.cardCount { return lhs.cardCount > rhs.cardCount }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .mastery:
            return filtered.sorted { lhs, rhs in
                let lm = libraryVM.masteryPercent(for: lhs.id)
                let rm = libraryVM.masteryPercent(for: rhs.id)
                if lm != rm { return lm > rm }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private var totalChaptersCount: Int {
        libraryVM.decks.reduce(0) { $0 + libraryVM.chapterNames(for: $1).count }
    }

    public var body: some View {
        let decks = displayedDecks

        ScrollView {
            VStack(alignment: .leading, spacing: LunarTokens.space5) {
                headerStrip

                if !libraryVM.decks.isEmpty {
                    filterBar
                }

                if libraryVM.isLoading && libraryVM.decks.isEmpty {
                    ProgressView("Loading decks")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if decks.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: LunarTokens.space4) {
                        ForEach(decks) { deck in
                            deckCard(for: deck, currentOrder: decks.map(\.id))
                        }
                    }
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: decks.map(\.id))
                }
            }
            .padding(LunarTokens.space6)
        }
        .reportWindowFrame { rect in
            libraryVM.deckDragCoordinator.libraryBounds = rect
        }
        .onDisappear {
            libraryVM.deckDragCoordinator.resetFrames()
            _ = libraryVM.deckDragCoordinator.endDrag()
        }
        .navigationTitle("Library")
        .searchable(
            text: $libraryVM.searchQuery,
            isPresented: $isSearchPresented,
            placement: .lunarToolbar,
            prompt: "Search decks"
        )
        .background {
            Button("") {
                isSearchPresented = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .sheet(item: $deckPendingRename) { deck in
            RenameDeckSheet(currentTitle: deck.title) { updatedTitle in
                Task {
                    await libraryVM.renameDeck(id: deck.id, title: updatedTitle)
                }
            }
        }
        .confirmationDialog(
            "Delete Deck",
            isPresented: Binding(
                get: { deckPendingDelete != nil },
                set: { if !$0 { deckPendingDelete = nil } }
            ),
            presenting: deckPendingDelete
        ) { deck in
            Button("Delete \"\(deck.title)\"", role: .destructive) {
                Task { await libraryVM.deleteDeck(id: deck.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deck in
            Text("This removes \"\(deck.title)\" and its \(deck.cardCount) cards. This action cannot be undone.")
        }
    }

    private var headerStrip: some View {
        HStack(spacing: LunarTokens.space4) {
            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Library")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(libraryVM.decks.count) decks · \(totalChaptersCount) chapters · \(libraryVM.totalCards) cards")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("New Deck", action: onNewDeck)
                .buttonStyle(MonochromeProminentButtonStyle())

            Button {
                libraryVM.requestedImportExportDeckId = nil
                libraryVM.requestedImportExportTab = .import
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                    Text("Import")
                }
            }
            .buttonStyle(MonochromeGlassButtonStyle())
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space4)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
    }

    private var filterBar: some View {
        HStack(spacing: LunarTokens.space3) {
            LunarMenuPicker(
                selection: $selectedCategory,
                options: [(SubjectCategory?.none, "All Categories")]
                    + SubjectCategory.allCases.map { (SubjectCategory?.some($0), $0.rawValue) }
            )

            LunarMenuPicker(
                selection: $sortOrder,
                options: LibrarySortOrder.allCases.map { ($0, $0.displayName) }
            )

            if selectedCategory != nil || !libraryVM.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear") {
                    selectedCategory = nil
                    libraryVM.searchQuery = ""
                }
                .buttonStyle(MonochromeGlassButtonStyle(compact: true))
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func deckCard(for deck: Deck, currentOrder: [String]) -> some View {
        let chapters = libraryVM.chapterNames(for: deck)
        let structureText: String = chapters.isEmpty
            ? "No chapters"
            : "\(chapters.count == 1 ? "1 chapter" : "\(chapters.count) chapters") · \(chapters.joined(separator: ", "))"
        let cards = libraryVM.cards(for: deck.id)
        let dueCards = cards.filter { $0.isDue() }

        DeckCardView(
            deck: deck,
            masteryRatio: libraryVM.masteryRatio(for: deck.id),
            masteryPercent: libraryVM.masteryPercent(for: deck.id),
            structureSummary: structureText,
            onOpen: {
                guard libraryVM.deckDragCoordinator.draggingDeck == nil else { return }
                libraryVM.selection = .deck(deck.id)
            },
            onEdit: {
                onEditDeck(deck)
            },
            onDelete: {
                deckPendingDelete = deck
            },
            onRename: {
                deckPendingRename = deck
            },
            onStudyDue: dueCards.isEmpty ? nil : {
                onStartStudy(StudyLaunchRequest(deck: deck, cards: dueCards, mode: .standard))
            },
            onStudyAll: cards.isEmpty ? nil : {
                onStartStudy(StudyLaunchRequest(deck: deck, cards: cards, mode: .standard))
            },
            onExport: {
                libraryVM.requestedImportExportDeckId = deck.id
                libraryVM.requestedImportExportTab = .export
            },
            canDragToReorder: canReorder,
            isBeingDragged: libraryVM.deckDragCoordinator.draggingDeck?.id == deck.id,
            onDragChanged: { fallbackLocation in
                let windowPt = LunarWindowCoordinates.currentPointerLocation() ?? fallbackLocation
                libraryVM.deckDragCoordinator.updateDrag(
                    deck: deck,
                    currentOrder: currentOrder,
                    rawLocation: windowPt
                )
            },
            onDragEnded: {
                let previousOrder = libraryVM.decks.map(\.id)
                if let finalOrder = libraryVM.deckDragCoordinator.endDrag(),
                   finalOrder != previousOrder {
                    let rollback = libraryVM.applyLocalDeckOrder(finalOrder)
                    Task {
                        await libraryVM.persistDeckOrder(orderedIds: finalOrder, rollbackDecks: rollback)
                    }
                }
            }
        )
        .reportWindowFrame { rect in
            libraryVM.deckDragCoordinator.deckFrames[deck.id] = rect
        }
        .onDisappear {
            libraryVM.deckDragCoordinator.deckFrames.removeValue(forKey: deck.id)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !libraryVM.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCategory != nil {
            ContentUnavailableView(
                "No Matching Decks",
                systemImage: "magnifyingglass",
                description: Text("Clear search or category filter to see all decks.")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            ContentUnavailableView {
                Label("No Decks", systemImage: "square.grid.2x2")
            } description: {
                Text("Create a deck to organize chapters and flashcards.")
            } actions: {
                Button("New Deck", action: onNewDeck)
                    .buttonStyle(MonochromeProminentButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }
}

private struct RenameDeckSheet: View {
    let currentTitle: String
    let onRename: (String) -> Void

    @State private var draftTitle: String
    @Environment(\.dismiss) private var dismiss

    init(currentTitle: String, onRename: @escaping (String) -> Void) {
        self.currentTitle = currentTitle
        self.onRename = onRename
        _draftTitle = State(initialValue: currentTitle)
    }

    private var trimmed: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && trimmed != currentTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            Text("Rename Deck")
                .font(.system(size: 16, weight: .semibold))

            TextField("Deck title", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if canSave {
                        onRename(trimmed)
                        dismiss()
                    }
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onRename(trimmed)
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
