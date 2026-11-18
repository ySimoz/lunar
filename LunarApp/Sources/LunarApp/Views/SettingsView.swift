import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standard 4-tab macOS `Settings` window (`⌘,`) backed by `lunar-core` preferences.
public struct SettingsView: View {
    @Bindable var libraryVM: LibraryViewModel
    @Bindable var processManager: CoreProcessManager
    @AppStorage("lunar.showPomodoroInMenuBar") private var showPomodoroInMenuBar: Bool = true
    @State private var draft: UserPreferences = UserPreferences()
    @State private var didLoadDraft = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var pendingRestoreData: Data?
    @State private var pendingRestoreFilename: String = ""
    @State private var isConfirmingRestore = false
    @State private var backupStatusMessage: String?
    @State private var backupErrorMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    public init(libraryVM: LibraryViewModel, processManager: CoreProcessManager) {
        self.libraryVM = libraryVM
        self.processManager = processManager
    }

    public var body: some View {
        TabView {
            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }

            typographyTab
                .tabItem {
                    Label("Typography", systemImage: "textformat")
                }

            studyTab
                .tabItem {
                    Label("Study", systemImage: "slider.horizontal.3")
                }

            dataTab
                .tabItem {
                    Label("Data", systemImage: "internaldrive")
                }
        }
        .frame(width: 500, height: 390)
        .alert("Restore library backup?", isPresented: $isConfirmingRestore) {
            Button("Restore", role: .destructive) {
                confirmRestoreBackup()
            }
            Button("Cancel", role: .cancel) {
                pendingRestoreData = nil
                pendingRestoreFilename = ""
            }
        } message: {
            Text("Restoring from \(pendingRestoreFilename) replaces all current decks, cards, and review history.")
        }
        .onAppear {
            draft = libraryVM.preferences
            didLoadDraft = true
        }
        .onChange(of: libraryVM.preferences) { _, latest in
            if draft != latest {
                draft = latest
            }
        }
        .onChange(of: draft) { _, newValue in
            guard didLoadDraft else { return }
            NSApplication.shared.appearance = SettingsViewModel.resolvedAppearance(for: newValue.colorMode)
            Task {
                await libraryVM.updatePreferences(newValue)
            }
        }
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            LabeledContent("Appearance") {
                LunarSegmentedControl(
                    selection: Binding(
                        get: { draft.colorMode ?? "" },
                        set: { draft.colorMode = $0 }
                    ),
                    options: [("", "System"), ("light", "Light"), ("dark", "Dark")]
                )
            }

            LabeledContent("Accent") {
                HStack(spacing: LunarTokens.space2) {
                    Circle()
                        .fill(LunarTokens.neutralHighlight)
                        .frame(width: 10, height: 10)
                    Text("Monochrome Slate")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Typography Tab

    private var typographyTab: some View {
        VStack(spacing: LunarTokens.space3) {
            Form {
                LabeledContent("Card font") {
                    LunarMenuPicker(
                        selection: $draft.fontFamily,
                        options: [("serif", "Serif (STIX Two)"), ("sans", "Sans (SF Pro)"), ("mono", "Mono (SF Mono)")]
                    )
                }

                LabeledContent("Font size") {
                    LunarMenuPicker(
                        selection: $draft.fontSize,
                        options: [("sm", "Small"), ("base", "Base"), ("lg", "Large"), ("xl", "Extra Large")]
                    )
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: LunarTokens.space1) {
                Text("Preview")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                MathView(
                    content: "$$\\int_{0}^{\\infty} e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$",
                    fontFamily: draft.fontFamily,
                    fontSize: draft.fontSize,
                    minHeight: 46,
                    maxHeight: 68
                )
            }
            .padding(LunarTokens.space3)
            .lunarGlassCard(cornerRadius: LunarTokens.controlRadius)
            .padding(.horizontal, LunarTokens.space4)
            .padding(.bottom, LunarTokens.space3)
        }
    }

    // MARK: - Study Tab

    private var studyTab: some View {
        Form {
            Toggle("Sound effects", isOn: $draft.soundEnabled)
                .toggleStyle(MonochromeGlassToggleStyle())

            LabeledContent("Audio preview") {
                Button("Test Chime") {
                    AudioCueManager.shared.play(.chime, enabled: true)
                }
                .buttonStyle(.bordered)
            }

            Toggle("Auto-reveal proof steps", isOn: $draft.autoRevealSteps)
                .toggleStyle(MonochromeGlassToggleStyle())

            Toggle("Show Pomodoro timer in menu bar", isOn: $showPomodoroInMenuBar)
                .toggleStyle(MonochromeGlassToggleStyle())

            Stepper(
                "Default Gauntlet lives: \(draft.defaultLives)",
                value: $draft.defaultLives,
                in: 1...10
            )
            .monospacedDigit()
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Data Tab

    private var dataTab: some View {
        Form {
            LabeledContent("Backend status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(
                            processManager.state.isConnected
                                ? LunarTokens.neutralHighlight
                                : Color.secondary.opacity(0.35)
                        )
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if case .connected(let url) = processManager.state {
                LabeledContent("Server address") {
                    Text(url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Library") {
                Text("\(libraryVM.decks.count) decks · \(libraryVM.totalCards) cards")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Export") {
                Button("Export Deck") {
                    libraryVM.requestedImportExportTab = .export
                }
                .buttonStyle(.bordered)
                .disabled(!processManager.state.isConnected || libraryVM.decks.isEmpty)
            }

            LabeledContent("Database backup") {
                HStack(spacing: LunarTokens.space2) {
                    Button {
                        exportDatabaseBackup()
                    } label: {
                        if isBackingUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Export Backup")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!processManager.state.isConnected || isBackingUp || isRestoring)

                    Button("Restore Backup...") {
                        pickBackupForRestore()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!processManager.state.isConnected || isBackingUp || isRestoring)
                }
            }

            if let error = backupErrorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            } else if let status = backupStatusMessage {
                Text(status)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func exportDatabaseBackup() {
        backupErrorMessage = nil
        backupStatusMessage = nil

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.canCreateDirectories = true
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "lunar-backup-\(dateFormatter.string(from: Date())).db"

        Task {
            let response = await panel.begin()
            guard response == .OK, let destinationURL = panel.url else { return }
            isBackingUp = true
            defer { isBackingUp = false }
            do {
                let data = try await libraryVM.exportBackup()
                try data.write(to: destinationURL, options: .atomic)
                backupStatusMessage = "Saved \(destinationURL.lastPathComponent)"
            } catch {
                backupErrorMessage = error.localizedDescription
            }
        }
    }

    private func pickBackupForRestore() {
        backupErrorMessage = nil
        backupStatusMessage = nil

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "db") ?? .data,
            UTType(filenameExtension: "sqlite") ?? .data,
            UTType(filenameExtension: "sqlite3") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        Task {
            let response = await panel.begin()
            guard response == .OK, let sourceURL = panel.url else { return }
            do {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { sourceURL.stopAccessingSecurityScopedResource() }
                }
                let data = try Data(contentsOf: sourceURL)
                pendingRestoreData = data
                pendingRestoreFilename = sourceURL.lastPathComponent
                isConfirmingRestore = true
            } catch {
                backupErrorMessage = error.localizedDescription
            }
        }
    }

    private func confirmRestoreBackup() {
        guard let data = pendingRestoreData else { return }
        pendingRestoreData = nil
        isRestoring = true
        backupErrorMessage = nil
        backupStatusMessage = nil

        Task {
            defer { isRestoring = false }
            do {
                let counts = try await libraryVM.restoreBackup(data)
                backupStatusMessage = "Restored \(counts.decks) decks and \(counts.cards) cards"
            } catch {
                backupErrorMessage = error.localizedDescription
            }
        }
    }

    private var statusText: String {
        switch processManager.state {
        case .idle: "Idle"
        case .starting: "Starting"
        case .connected: "Connected"
        case .failed: "Unavailable"
        }
    }
}
