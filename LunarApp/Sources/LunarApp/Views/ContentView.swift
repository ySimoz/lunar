import AppKit
import SwiftUI

/// Root `NavigationSplitView` shell hosting the sidebar, deck library, deck detail,
/// workspace views, and full-window distraction-free study focus overlay.
public struct ContentView: View {
    @Bindable var processManager: CoreProcessManager
    @Bindable var libraryVM: LibraryViewModel
    @Bindable var pomodoroVM: PomodoroViewModel
    @Bindable var grapherVM: GrapherViewModel

    @State private var isCreatingDeck = false
    @State private var editingDeck: Deck?
    @State private var activeStudyRequest: StudyLaunchRequest?
    @State private var showDelayedStartingIndicator = false

    public init(
        processManager: CoreProcessManager,
        libraryVM: LibraryViewModel,
        pomodoroVM: PomodoroViewModel,
        grapherVM: GrapherViewModel = GrapherViewModel()
    ) {
        self.processManager = processManager
        self.libraryVM = libraryVM
        self.pomodoroVM = pomodoroVM
        self.grapherVM = grapherVM
    }

    public var body: some View {
        ZStack {
            if let request = activeStudyRequest {
                StudySessionView(
                    request: request,
                    preferences: libraryVM.preferences,
                    client: processManager.client,
                    onClose: {
                        withAnimation(LunarTokens.revealAnimation) {
                            activeStudyRequest = nil
                        }
                    },
                    onSessionFinished: {
                        await libraryVM.loadAll()
                    }
                )
                .id(request.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(1)
            } else {
                mainWorkspaceShell
                    .transition(.opacity)
            }
        }
        .animation(LunarTokens.revealAnimation, value: activeStudyRequest != nil)
        .lunarWindowVibrancy()
        .sheet(isPresented: $isCreatingDeck) {
            DeckEditorSheet { title, description, category, difficulty, chapters in
                Task {
                    if let created = await libraryVM.createDeck(
                        title: title,
                        description: description,
                        category: category,
                        difficulty: difficulty,
                        chapters: chapters
                    ) {
                        libraryVM.selection = .deck(created.id)
                    }
                }
            }
        }
        .sheet(item: $editingDeck) { deck in
            DeckEditorSheet(existingDeck: deck) { title, description, category, difficulty, chapters in
                var updated = deck
                updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.category = category
                updated.difficulty = difficulty
                updated.chapters = chapters
                Task {
                    await libraryVM.updateDeck(updated)
                }
            }
        }
        .sheet(item: $libraryVM.requestedImportExportTab) { tab in
            ImportExportSheet(
                decks: libraryVM.decks,
                initialDeckId: libraryVM.requestedImportExportDeckId ?? activeDeckIdForImportExport,
                initialTab: tab,
                client: processManager.client
            ) { result in
                await libraryVM.loadAll()
                libraryVM.selection = .deck(result.deck.id)
            }
        }
        .onChange(of: libraryVM.requestedImportExportTab) { _, newValue in
            if newValue == nil {
                libraryVM.requestedImportExportDeckId = nil
            }
        }
    }

    private var mainWorkspaceShell: some View {
        NavigationSplitView {
            SidebarView(libraryVM: libraryVM)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 290)
        } detail: {
            detailContent
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if pomodoroVM.isRunning && libraryVM.selection != .tools {
                    Button {
                        libraryVM.selection = .tools
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "timer")
                                .font(.system(size: 11, weight: .medium))
                            Text(pomodoroVM.formattedTime)
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(LunarTokens.neutralHighlight)
                        .padding(.horizontal, LunarTokens.space2)
                        .padding(.vertical, 3)
                        .background(
                            Color.primary.opacity(0.08),
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(LunarTokens.hairlineBorder(), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open Focus Timer")
                }
            }
        }
        .reportWindowFrame { rect in
            libraryVM.dragCoordinator.workspaceBounds = rect
        }
        .overlay(alignment: .topLeading) {
            if let draggedCard = libraryVM.dragCoordinator.draggingCard {
                dragPreviewPill(for: draggedCard)
                    .position(libraryVM.dragCoordinator.dragLocation)
                    .allowsHitTesting(false)
            } else if let draggedDeck = libraryVM.deckDragCoordinator.draggingDeck {
                deckDragPreviewCard(for: draggedDeck)
                    .position(libraryVM.deckDragCoordinator.dragLocation)
                    .allowsHitTesting(false)
            }
        }
        .tint(LunarTokens.neutralHighlight)
        .background {
            // Command-N shortcut for creating a deck
            Button("") {
                if processManager.state.isConnected {
                    isCreatingDeck = true
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .hidden()
        }
    }

    private func startStudy(_ request: StudyLaunchRequest) {
        withAnimation(LunarTokens.revealAnimation) {
            activeStudyRequest = request
        }
    }

    @ViewBuilder
    private func dragPreviewPill(for card: Flashcard) -> some View {
        let targetHint: String? = if let deckId = libraryVM.dragCoordinator.hoveredDeckId,
                                     let deck = libraryVM.deck(for: deckId) {
            "Move to \(deck.title)"
        } else if let chapter = libraryVM.dragCoordinator.hoveredChapter {
            "Move to \(chapter)"
        } else {
            nil
        }

        HStack(spacing: LunarTokens.space2) {
            CardTypeDot(card.cardType)
            VStack(alignment: .leading, spacing: 2) {
                Text(MathPlainText.format(card.front))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let targetHint {
                    Text(targetHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LunarTokens.neutralHighlight)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, LunarTokens.space3)
        .padding(.vertical, LunarTokens.space2)
        .frame(maxWidth: 280, alignment: .leading)
        .lunarGlassCard(cornerRadius: LunarTokens.controlRadius, isSelected: true)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }

    @ViewBuilder
    private func deckDragPreviewCard(for deck: Deck) -> some View {
        VStack(alignment: .leading, spacing: LunarTokens.space2) {
            HStack {
                Text(deck.category.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(deck.difficulty.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(deck.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(deck.cardCount) cards")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(LunarTokens.space4)
        .frame(width: 260, alignment: .leading)
        .lunarGlassCard(cornerRadius: LunarTokens.cardRadius, isSelected: true)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    private var activeDeckIdForImportExport: String? {
        if case .deck(let id) = libraryVM.selection {
            return id
        }
        return nil
    }

    @ViewBuilder
    private var detailContent: some View {
        switch processManager.state {
        case .idle, .starting:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if showDelayedStartingIndicator {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .task(id: processManager.state) {
                    showDelayedStartingIndicator = false
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled {
                        showDelayedStartingIndicator = true
                    }
                }

        case .failed(let message):
            ContentUnavailableView {
                Label("Core Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                HStack(spacing: LunarTokens.space3) {
                    Button("Retry") {
                        Task { await reconnect() }
                    }
                    .buttonStyle(MonochromeProminentButtonStyle())

                    Button("Locate Binary") {
                        chooseBinaryAndStart()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .connected:
            activeDestinationView
                .lunarSuppressTopScrollEdge()
        }
    }

    @ViewBuilder
    private var activeDestinationView: some View {
        switch libraryVM.selection ?? .today {
        case .today:
            DeckLibraryView(
                libraryVM: libraryVM,
                onStartStudy: { startStudy($0) }
            )

        case .library:
            LibraryView(
                libraryVM: libraryVM,
                onNewDeck: { isCreatingDeck = true },
                onEditDeck: { editingDeck = $0 },
                onStartStudy: { startStudy($0) }
            )

        case .deck(let deckId):
            if let deck = libraryVM.deck(for: deckId) {
                DeckDetailView(
                    deck: deck,
                    libraryVM: libraryVM,
                    client: processManager.client,
                    onEditDeck: { editingDeck = $0 },
                    onStartStudy: { startStudy($0) }
                )
            } else {
                ContentUnavailableView(
                    "Deck Not Found",
                    systemImage: "folder",
                    description: Text("Select a deck from the sidebar.")
                )
            }

        case .gauntlet:
            GauntletSetupView(libraryVM: libraryVM) { request in
                startStudy(request)
            }

        case .analytics:
            AnalyticsView(libraryVM: libraryVM, client: processManager.client)

        case .tools:
            ToolsView(
                pomodoroVM: pomodoroVM,
                grapherVM: grapherVM
            )
        }
    }

    private func reconnect(binaryURL: URL? = nil) async {
        do {
            let client = try await processManager.start(customBinaryURL: binaryURL)
            libraryVM.configure(client: client)
            await libraryVM.loadAll()
        } catch {}
    }

    private func chooseBinaryAndStart() {
        let panel = NSOpenPanel()
        panel.title = "Select lunar-core Binary"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await reconnect(binaryURL: url) }
        }
    }
}
