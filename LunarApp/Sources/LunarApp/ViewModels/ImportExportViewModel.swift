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
    public var importAPKGData: Data?
    public var importFilename: String?
    public var skipDuplicates: Bool = true
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
        if importFormat == .apkg {
            return !(importAPKGData?.isEmpty ?? true)
        }
        guard !importContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if case .newDeck = importTarget {
            return !newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    public func loadExportPreview() async {
        guard let client, !exportDeckId.isEmpty, exportFormat.supportsExport else {
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
        let detected = IOFormat.detect(from: url)
        if detected == .apkg {
            let data = try Data(contentsOf: url)
            importFormat = .apkg
            importAPKGData = data
            importFilename = url.lastPathComponent
            importContent = ""
        } else {
            let text = try String(contentsOf: url, encoding: .utf8)
            importContent = text
            importAPKGData = nil
            importFilename = url.lastPathComponent
            if let detected {
                importFormat = detected
            }
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
            let trimmedTitle = newDeckTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmedTitle.isEmpty ? nil : trimmedTitle
            category = newDeckCategory
        }

        do {
            let result: ImportResult
            if importFormat == .apkg {
                guard let apkgData = importAPKGData, !apkgData.isEmpty else {
                    return nil
                }
                result = try await client.importAPKG(
                    apkgData,
                    deckId: targetDeckId,
                    deckName: title,
                    skipDuplicates: skipDuplicates
                )
            } else {
                let trimmedTopic = targetTopic.trimmingCharacters(in: .whitespacesAndNewlines)
                let request = ImportRequest(
                    format: importFormat,
                    content: importContent,
                    targetDeckId: targetDeckId,
                    newDeckTitle: title,
                    category: category,
                    targetTopic: trimmedTopic.isEmpty ? nil : trimmedTopic
                )
                result = try await client.importCards(request)
            }
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
