import SwiftUI

/// Modal sheet for creating or editing a `Deck`.
public struct DeckEditorSheet: View {
    public let existingDeck: Deck?
    public let onSave: (String, String, SubjectCategory, Difficulty, [String]) -> Void

    @State private var title: String
    @State private var description: String
    @State private var category: SubjectCategory
    @State private var difficulty: Difficulty
    @State private var chapters: [String]
    @State private var newChapterText: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        existingDeck: Deck? = nil,
        onSave: @escaping (String, String, SubjectCategory, Difficulty, [String]) -> Void
    ) {
        self.existingDeck = existingDeck
        self.onSave = onSave
        _title = State(initialValue: existingDeck?.title ?? "")
        _description = State(initialValue: existingDeck?.description ?? "")
        _category = State(initialValue: existingDeck?.category ?? .generalMath)
        _difficulty = State(initialValue: existingDeck?.difficulty ?? .medium)
        _chapters = State(initialValue: existingDeck?.chapters ?? [])
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingDeck == nil ? "New Deck" : "Edit Deck")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existingDeck == nil ? "Create" : "Save") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MonochromeProminentButtonStyle())
                .disabled(!canSave)
            }
            .padding(.horizontal, LunarTokens.space5)
            .padding(.vertical, LunarTokens.space4)

            Divider()

            Form {
                Section("Details") {
                    TextField("Title", text: $title, prompt: Text(""))
                    TextField("Description", text: $description, prompt: Text(""), axis: .vertical)
                        .lineLimit(2...4)

                    LabeledContent("Category") {
                        LunarMenuPicker(
                            selection: $category,
                            options: SubjectCategory.allCases.map { ($0, $0.rawValue) }
                        )
                    }

                    LabeledContent("Difficulty") {
                        LunarMenuPicker(
                            selection: $difficulty,
                            options: Difficulty.allCases.map { ($0, $0.displayName) }
                        )
                    }
                }

                Section("Chapters") {
                    HStack(spacing: LunarTokens.space2) {
                        TextField("Add chapter", text: $newChapterText, prompt: Text(""))
                            .onSubmit(addChapter)
                        Button("Add", action: addChapter)
                            .disabled(newChapterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if chapters.isEmpty {
                        Text("No chapters defined")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(chapters.enumerated()), id: \.offset) { idx, chapter in
                            HStack {
                                Text(chapter)
                                    .font(.system(size: 13))
                                Spacer()
                                Button {
                                    chapters.remove(at: idx)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove chapter")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 480)
    }

    private func addChapter() {
        let trimmed = newChapterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chapters.contains(trimmed) else { return }
        chapters.append(trimmed)
        newChapterText = ""
    }

    private func commit() {
        guard canSave else { return }
        onSave(title, description, category, difficulty, chapters)
        dismiss()
    }
}
