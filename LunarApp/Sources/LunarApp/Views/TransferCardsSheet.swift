import SwiftUI

/// Modal sheet for moving one or more cards to a target deck and chapter (or creating a new chapter).
public struct TransferCardsSheet: View {
    private enum ChapterChoice: Hashable {
        case general
        case existing(String)
        case createNew
    }

    public let cards: [Flashcard]
    public let sourceDeckId: String
    public let decks: [Deck]
    public let onTransfer: (String, String?) async -> Void

    @State private var selectedDeckId: String
    @State private var chapterChoice: ChapterChoice = .general
    @State private var newChapterName: String = ""
    @State private var isSubmitting = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        cards: [Flashcard],
        sourceDeckId: String,
        decks: [Deck],
        onTransfer: @escaping (String, String?) async -> Void
    ) {
        self.cards = cards
        self.sourceDeckId = sourceDeckId
        self.decks = decks
        self.onTransfer = onTransfer

        let initialDeckId = decks.first(where: { $0.id != sourceDeckId })?.id ?? sourceDeckId
        _selectedDeckId = State(initialValue: initialDeckId)

        if let initialDeck = decks.first(where: { $0.id == initialDeckId }),
           let firstChapter = initialDeck.chapters.first {
            _chapterChoice = State(initialValue: .existing(firstChapter))
        } else {
            _chapterChoice = State(initialValue: .general)
        }
    }

    private var selectedDeck: Deck? {
        decks.first(where: { $0.id == selectedDeckId })
    }

    private var resolvedTopic: String? {
        switch chapterChoice {
        case .general:
            return nil
        case .existing(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .createNew:
            let trimmed = newChapterName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private var canSubmit: Bool {
        guard !cards.isEmpty, selectedDeck != nil, !isSubmitting else { return false }
        if case .createNew = chapterChoice {
            let trimmed = newChapterName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != DeckDetailViewModel.uncategorizedChapterTitle else {
                return false
            }
        }
        let targetTopicNormalized = resolvedTopic ?? ""
        let allAlreadyAtDestination = cards.allSatisfy { card in
            card.deckId == selectedDeckId
                && card.topic.trimmingCharacters(in: .whitespacesAndNewlines) == targetTopicNormalized
        }
        return !allAlreadyAtDestination
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LunarTokens.space3) {
                Text(cards.count == 1 ? "Move Card" : "Move \(cards.count) Cards")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, LunarTokens.space5)
            .padding(.vertical, LunarTokens.space4)

            Divider()

            Form {
                Section("Destination") {
                    LabeledContent("Deck") {
                        LunarMenuPicker(
                            selection: $selectedDeckId,
                            options: decks.map { deck in
                                (deck.id, deck.id == sourceDeckId ? "\(deck.title) (Current)" : deck.title)
                            }
                        )
                    }

                    LabeledContent("Chapter") {
                        LunarMenuPicker(
                            selection: $chapterChoice,
                            options: [(ChapterChoice.general, DeckDetailViewModel.uncategorizedChapterTitle)]
                                + (selectedDeck?.chapters ?? []).map { (ChapterChoice.existing($0), $0) }
                                + [(ChapterChoice.createNew, "New Chapter")]
                        )
                    }

                    if case .createNew = chapterChoice {
                        TextField("Chapter name", text: $newChapterName, prompt: Text(""))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack(spacing: LunarTokens.space3) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isSubmitting ? "Moving" : "Move") {
                    isSubmitting = true
                    let targetId = selectedDeckId
                    let topic = resolvedTopic
                    Task {
                        await onTransfer(targetId, topic)
                        isSubmitting = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MonochromeProminentButtonStyle())
                .disabled(!canSubmit)
            }
            .padding(.horizontal, LunarTokens.space5)
            .padding(.vertical, LunarTokens.space4)
        }
        .frame(width: 420, height: 290)
        .onChange(of: selectedDeckId) { _, _ in
            if case .existing(let currentName) = chapterChoice,
               selectedDeck?.chapters.contains(currentName) == true {
                return
            }
            if case .createNew = chapterChoice {
                return
            }
            if let first = selectedDeck?.chapters.first {
                chapterChoice = .existing(first)
            } else {
                chapterChoice = .general
            }
        }
    }
}
