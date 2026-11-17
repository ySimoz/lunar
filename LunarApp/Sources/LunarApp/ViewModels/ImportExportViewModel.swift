import Foundation
import Observation

/// Active tab inside `ImportExportSheet`.
public enum ImportExportTab: String, CaseIterable, Identifiable, Sendable {
    case export = "Export"
    case `import` = "Import"

    public var id: String { rawValue }
}

/// Destination for imported cards (`newDeck` or an existing deck ID).
public enum ImportTargetSelection: Hashable, Sendable {
    case newDeck
    case existing(String)
}

/// Coordinates deck export previews and card bulk imports via `CoreClientProtocol`.
@Observable
@MainActor
public final class ImportExportViewModel {
    public var activeTab: ImportExportTab
    public var decks: [Deck]

    // Export state
    public var exportDeckId: String
    public var exportFormat: IOFormat = .markdown
    public private(set) var exportResult: ExportResult?
    public private(set) var isExporting: Bool = false
    public var didCopyExport: Bool = false
    public var exportError: String?

    // Import state
    public var importTarget: ImportTargetSelection
    public var newDeckTitle: String = ""
    public var newDeckCategory: SubjectCategory = .generalMath
    public var importFormat: IOFormat = .markdown
    public var targetTopic: String = ""
    public var importContent: String = ""
    public private(set) var isImporting: Bool = false
    public private(set) var lastImportResult: ImportResult?
    public var importError: String?

    private let client: (any CoreClientProtocol)?

    public init(
        decks: [Deck],
        initialDeckId: String? = nil,
        initialTab: ImportExportTab = .export,
        client: (any CoreClientProtocol)? = nil
    ) {
        self.decks = decks
        self.activeTab = initialTab
        self.client = client

        let resolvedDeckId = initialDeckId
            .flatMap { id in decks.contains(where: { $0.id == id }) ? id : nil }
            ?? decks.first?.id
            ?? ""
        self.exportDeckId = resolvedDeckId
        self.importTarget = resolvedDeckId.isEmpty ? .newDeck : .existing(resolvedDeckId)
    }

    public var canImport: Bool {
        guard !importContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if case .newDeck = importTarget {
            return !newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    public func loadExportPreview() async {
        guard let client, !exportDeckId.isEmpty else {
            exportResult = nil
            return
        }
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        do {
            exportResult = try await client.exportDeck(deckId: exportDeckId, format: exportFormat)
        } catch {
            exportResult = nil
            exportError = error.localizedDescription
        }
    }

    public func loadImportedFile(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        importContent = text
        if let detected = IOFormat.detect(from: url) {
            importFormat = detected
        }
        if case .newDeck = importTarget,
           newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newDeckTitle = url.deletingPathExtension().lastPathComponent
        }
        importError = nil
    }

    @discardableResult
    public func performImport() async -> ImportResult? {
        guard let client, canImport else { return nil }
        isImporting = true
        importError = nil
        defer { isImporting = false }

        let targetDeckId: String?
        let title: String?
        let category: SubjectCategory?

        switch importTarget {
        case .existing(let id):
            targetDeckId = id
            title = nil
            category = nil
        case .newDeck:
            targetDeckId = nil
            title = newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            category = newDeckCategory
        }

        let trimmedTopic = targetTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = ImportRequest(
            format: importFormat,
            content: importContent,
            targetDeckId: targetDeckId,
            newDeckTitle: title,
            category: category,
            targetTopic: trimmedTopic.isEmpty ? nil : trimmedTopic
        )

        do {
            let result = try await client.importCards(request)
            lastImportResult = result
            if !decks.contains(where: { $0.id == result.deck.id }) {
                decks.append(result.deck)
            }
            return result
        } catch {
            importError = error.localizedDescription
            return nil
        }
    }
}
