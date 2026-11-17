import Foundation
import Observation

/// Filter modes for the Analytics Card Inspector table.
public enum CardInspectorFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case due = "Due"
    case lowEase = "Low Ease"

    public var id: String { rawValue }
}

/// Manages Analytics summary loading (`14d` / `30d`) and card inspector filtering.
@Observable
@MainActor
public final class StatsViewModel {
    public nonisolated static let lowEaseThreshold: Double = 2.2

    public var daysWindow: Int = 30
    public private(set) var summary: StatsSummary?
    public private(set) var isLoading: Bool = false
    public var errorMessage: String?

    public var inspectorFilter: CardInspectorFilter = .all
    public var inspectorSearch: String = ""
    public var selectedCardID: String?

    private let client: (any CoreClientProtocol)?

    public init(client: (any CoreClientProtocol)? = nil) {
        self.client = client
    }

    public func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            summary = try await client.getStats(days: daysWindow)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public nonisolated static func filterCards(
        _ cards: [Flashcard],
        filter: CardInspectorFilter,
        query: String,
        now: Date = Date()
    ) -> [Flashcard] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let stageFiltered = cards.filter { card in
            switch filter {
            case .all:
                true
            case .due:
                card.isDue(relativeTo: now)
            case .lowEase:
                card.easeFactor < lowEaseThreshold
            }
        }

        let searched: [Flashcard]
        if trimmed.isEmpty {
            searched = stageFiltered
        } else {
            searched = stageFiltered.filter { card in
                card.front.lowercased().contains(trimmed)
                    || card.back.lowercased().contains(trimmed)
                    || card.topic.lowercased().contains(trimmed)
                    || card.tags.contains { $0.lowercased().contains(trimmed) }
            }
        }

        if filter == .lowEase {
            return searched.sorted { $0.easeFactor < $1.easeFactor }
        }
        return searched
    }
}
