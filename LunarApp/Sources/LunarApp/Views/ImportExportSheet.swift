import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Native `FileDocument` wrapper used by `.fileExporter` to save exported decks.
public struct ExportDocument: FileDocument, Sendable {
    public static var readableContentTypes: [UTType] {
        [.plainText, .commaSeparatedText, .tabSeparatedText, .json]
    }

    public var text: String

    public init(text: String = "") {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = decoded
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Modal sheet for either exporting a deck (`Markdown`, `Anki TSV`, `CSV`, `JSON`)
/// or importing cards into an existing or new deck, strictly scoped to the triggered mode.
public struct ImportExportSheet: View {
    @State private var vm: ImportExportViewModel
    @State private var isShowingFileExporter = false
    @State private var isShowingFileImporter = false
    @State private var copyResetTask: Task<Void, Never>?

    public let onImportComplete: @MainActor (ImportResult) async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public init(
        decks: [Deck],
        initialDeckId: String? = nil,
        initialTab: ImportExportTab = .export,
        client: (any CoreClientProtocol)?,
        onImportComplete: @escaping @MainActor (ImportResult) async -> Void
    ) {
        _vm = State(initialValue: ImportExportViewModel(
            decks: decks,
            initialDeckId: initialDeckId,
            initialTab: initialTab,
            client: client
        ))
        self.onImportComplete = onImportComplete
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            Group {
                switch vm.activeTab {
                case .export:
                    exportTab
                case .import:
                    importTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 560)
        .task(id: "\(vm.exportDeckId)-\(vm.exportFormat.rawValue)") {
            guard vm.activeTab == .export else { return }
            await vm.loadExportPreview()
        }
        .fileExporter(
            isPresented: $isShowingFileExporter,
            document: ExportDocument(text: vm.exportResult?.content ?? ""),
            contentType: vm.exportFormat.contentType,
            defaultFilename: vm.exportResult?.filename ?? "deck.\(vm.exportFormat.fileExtension)"
        ) { result in
            if case .failure(let error) = result {
                vm.exportError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [
                .plainText,
                .commaSeparatedText,
                .tabSeparatedText,
                .json,
                UTType(filenameExtension: "md") ?? .plainText,
                UTType(filenameExtension: "apkg") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try vm.loadImportedFile(from: url)
                } catch {
                    vm.importError = error.localizedDescription
                }
            case .failure(let error):
                vm.importError = error.localizedDescription
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text(vm.activeTab == .export ? "Export Deck" : "Import Cards")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, LunarTokens.space5)
        .padding(.vertical, LunarTokens.space4)
    }

    // MARK: - Export Tab

    private var exportTab: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            HStack(spacing: LunarTokens.space4) {
                HStack(spacing: LunarTokens.space2) {
                    Text("Deck")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    LunarMenuPicker(
                        selection: $vm.exportDeckId,
                        options: vm.decks.map { ($0.id, $0.title) }
                    )
                }

                Spacer()

                HStack(spacing: LunarTokens.space2) {
                    Text("Format")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    LunarMenuPicker(
                        selection: $vm.exportFormat,
                        options: IOFormat.exportCases.map { ($0, $0.displayName) }
                    )
                }
            }

            if let error = vm.exportError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            Group {
                if vm.decks.isEmpty {
                    ContentUnavailableView(
                        "No Decks Available",
                        systemImage: "square.stack.3d.up",
                        description: Text("Create or import a deck before exporting.")
                    )
                } else if vm.isExporting {
                    ProgressView("Preparing export")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = vm.exportResult {
                    ScrollView {
                        Text(result.content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(LunarTokens.space4)
                    }
                    .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "doc.text",
                        description: Text("Select a deck to preview exported content.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: LunarTokens.space3) {
                if let result = vm.exportResult {
                    Text(result.filename)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    copyExportToPasteboard()
                } label: {
                    Label(
                        vm.didCopyExport ? "Copied" : "Copy",
                        systemImage: vm.didCopyExport ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(vm.exportResult == nil)

                Button("Save to File") {
                    isShowingFileExporter = true
                }
                .buttonStyle(MonochromeProminentButtonStyle())
                .disabled(vm.exportResult == nil)
            }
        }
        .padding(LunarTokens.space5)
    }

    // MARK: - Import Tab

    private var importTab: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space4) {
            VStack(spacing: LunarTokens.space3) {
                HStack(spacing: LunarTokens.space4) {
                    HStack(spacing: LunarTokens.space2) {
                        Text("Target Deck")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        LunarMenuPicker(
                            selection: $vm.importTarget,
                            options: [(ImportTargetSelection.newDeck, "New Deck")]
                                + vm.decks.map { (ImportTargetSelection.existing($0.id), $0.title) }
                        )
                    }

                    Spacer()

                    HStack(spacing: LunarTokens.space2) {
                        Text("Format")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        LunarMenuPicker(
                            selection: $vm.importFormat,
                            options: IOFormat.importCases.map { ($0, $0.displayName) }
                        )
                    }
                }

                if case .newDeck = vm.importTarget {
                    HStack(spacing: LunarTokens.space4) {
                        TextField(
                            "",
                            text: $vm.newDeckTitle,
                            prompt: Text(vm.importFormat == .apkg ? "Deck title (optional)" : "Deck title")
                        )
                        .accessibilityLabel("Deck Title")
                        .textFieldStyle(.roundedBorder)

                        if vm.importFormat != .apkg {
                            LunarMenuPicker(
                                selection: $vm.newDeckCategory,
                                options: SubjectCategory.allCases.map { ($0, $0.rawValue) }
                            )
                        }
                    }
                }

                if vm.importFormat != .apkg {
                    TextField("", text: $vm.targetTopic, prompt: Text("Chapter"))
                        .accessibilityLabel("Target Chapter")
                        .textFieldStyle(.roundedBorder)
                }
            }

            if vm.importFormat == .apkg {
                apkgImportBody
            } else {
                HStack {
                    Text("Content")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose File") {
                        isShowingFileImporter = true
                    }
                    .buttonStyle(.bordered)
                }

                TextEditor(text: $vm.importContent)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(LunarTokens.space2)
                    .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = vm.importError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            } else if let result = vm.lastImportResult {
                Text("Imported \(result.importedCount) cards into \(result.deck.title)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(LunarTokens.neutralHighlight)
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        if let result = await vm.performImport() {
                            await onImportComplete(result)
                        }
                    }
                } label: {
                    if vm.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(MonochromeProminentButtonStyle())
                .disabled(!vm.canImport || vm.isImporting)
            }
        }
        .padding(LunarTokens.space5)
    }

    private var apkgImportBody: some View {
        VStack(alignment: .leading, spacing: LunarTokens.space3) {
            HStack {
                Text("Anki package")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose .apkg File") {
                    isShowingFileImporter = true
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: LunarTokens.space3) {
                Image(systemName: "archivebox")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)

                if let data = vm.importAPKGData, !data.isEmpty {
                    Text(vm.importFilename ?? "deck.apkg")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("No .apkg file selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(LunarTokens.space5)
            .lunarGlassCard(cornerRadius: LunarTokens.cardRadius)

            Toggle("Skip duplicate cards", isOn: $vm.skipDuplicates)
                .toggleStyle(MonochromeGlassToggleStyle())
        }
    }

    private func copyExportToPasteboard() {
        guard let content = vm.exportResult?.content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        vm.didCopyExport = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled {
                vm.didCopyExport = false
            }
        }
    }
}
