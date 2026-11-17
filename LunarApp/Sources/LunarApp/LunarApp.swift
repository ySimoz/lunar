import AppKit
import SwiftUI

@MainActor
final class LunarAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    let menuBarController = PomodoroMenuBarController()
    let focusCoordinator = WindowSearchFocusCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        focusCoordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusCoordinator.teardown()
        menuBarController.teardown()
        onTerminate?()
    }
}

/// Resigns search/text field focus when clicking non-input UI and replaces macOS
/// system-blue focus rings and text highlights with Lunar monochrome styling.
@MainActor
final class WindowSearchFocusCoordinator {
    private var mouseMonitor: Any?
    private var keyObserver: NSObjectProtocol?
    private var editObserver: NSObjectProtocol?
    private var responderObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func start() {
        guard mouseMonitor == nil else { return }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event) ?? event
        }

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToKeyWindow()
            }
        }

        editObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidBeginEditingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.styleActiveWindowResponders()
            }
        }

        attachToKeyWindow()
    }

    func teardown() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        if let editObserver {
            NotificationCenter.default.removeObserver(editObserver)
            self.editObserver = nil
        }
        responderObservations.values.forEach { $0.invalidate() }
        responderObservations.removeAll()
    }

    private func attachToKeyWindow() {
        for window in NSApp.windows {
            let key = ObjectIdentifier(window)
            if responderObservations[key] == nil {
                responderObservations[key] = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.styleActiveWindowResponders()
                    }
                }
            }
            stripToolbarSearchRings(in: window)
        }
        styleActiveWindowResponders()
    }

    private func handleMouseDown(_ event: NSEvent) -> NSEvent {
        guard let window = event.window else { return event }
        stripToolbarSearchRings(in: window)

        let rootView = window.contentView?.superview ?? window.contentView
        let hitView = rootView?.hitTest(event.locationInWindow)

        if let hitField = ancestor(of: hitView, matching: NSTextField.self) {
            hitField.focusRingType = .none
        }

        guard let textView = window.firstResponder as? NSTextView else {
            return event
        }

        let activeControl = (textView.delegate as? NSView) ?? textView
        let clickedInsideActive = hitView.map {
            $0 === activeControl || $0.isDescendant(of: activeControl)
        } ?? false
        let clickedTextInput = ancestor(of: hitView, matching: NSTextView.self) != nil
            || ancestor(of: hitView, matching: NSTextField.self) != nil

        if !clickedInsideActive && !clickedTextInput {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            window.makeFirstResponder(nil)
        }
        return event
    }

    private func styleActiveWindowResponders() {
        for window in NSApp.windows {
            stripToolbarSearchRings(in: window)
            guard let textView = window.firstResponder as? NSTextView else { continue }
            textView.insertionPointColor = NSColor.labelColor
            textView.selectedTextAttributes = [
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.18)
            ]
            if let field = textView.delegate as? NSTextField {
                field.focusRingType = .none
            }
        }
    }

    private func stripToolbarSearchRings(in window: NSWindow) {
        guard let items = window.toolbar?.items else { return }
        for item in items {
            if let searchItem = item as? NSSearchToolbarItem {
                searchItem.searchField.focusRingType = .none
            }
        }
    }

    private func ancestor<T: NSView>(of view: NSView?, matching type: T.Type) -> T? {
        var current = view
        while let candidate = current {
            if let matched = candidate as? T {
                return matched
            }
            current = candidate.superview
        }
        return nil
    }
}

@MainActor
final class PomodoroMenuBarController: NSObject {
    static let preferenceKey = "lunar.showPomodoroInMenuBar"

    private weak var pomodoroVM: PomodoroViewModel?
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    private let statusHeaderItem = NSMenuItem(title: "Focus — 25:00", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start", action: #selector(togglePlay), keyEquivalent: "")
    private let resetItem = NSMenuItem(title: "Reset", action: #selector(resetTimer), keyEquivalent: "")
    private let skipItem = NSMenuItem(title: "Skip", action: #selector(skipTimer), keyEquivalent: "")

    func configure(with pomodoroVM: PomodoroViewModel) {
        guard self.pomodoroVM !== pomodoroVM else {
            sync()
            return
        }
        self.pomodoroVM = pomodoroVM
        pomodoroVM.onStatusChange = { [weak self] in
            self?.sync()
        }

        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sync()
                }
            }
        }
        sync()
    }

    func teardown() {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        removeStatusItem()
    }

    func sync() {
        let isEnabled = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        guard isEnabled, let pomodoroVM else {
            removeStatusItem()
            return
        }

        let item = statusItem ?? createStatusItem()
        if let button = item.button {
            let nextTitle = pomodoroVM.isRunning ? " \(pomodoroVM.formattedTime)" : ""
            let nextPos: NSControl.ImagePosition = pomodoroVM.isRunning ? .imageLeading : .imageOnly
            if button.title != nextTitle { button.title = nextTitle }
            if button.imagePosition != nextPos { button.imagePosition = nextPos }
        }

        let nextHeader = "\(pomodoroVM.mode.displayName) — \(pomodoroVM.formattedTime)"
        let nextToggle = pomodoroVM.isRunning ? "Pause" : "Start"
        if statusHeaderItem.title != nextHeader { statusHeaderItem.title = nextHeader }
        if toggleItem.title != nextToggle { toggleItem.title = nextToggle }
    }

    private func createStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Pomodoro Timer")
            image?.isTemplate = true
            button.image = image
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let menu = NSMenu()
        statusHeaderItem.isEnabled = false
        toggleItem.target = self
        resetItem.target = self
        skipItem.target = self

        menu.addItem(statusHeaderItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(resetItem)
        menu.addItem(skipItem)
        item.menu = menu

        self.statusItem = item
        return item
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func togglePlay() {
        pomodoroVM?.togglePlay()
    }

    @objc private func resetTimer() {
        pomodoroVM?.reset()
    }

    @objc private func skipTimer() {
        pomodoroVM?.skip()
    }
}

@main
struct LunarApp: App {
    @NSApplicationDelegateAdaptor(LunarAppDelegate.self) private var appDelegate
    @State private var processManager = CoreProcessManager()
    @State private var libraryVM = LibraryViewModel()
    @State private var pomodoroVM = PomodoroViewModel()
    @State private var grapherVM = GrapherViewModel()
    @State private var didScheduleWebKitWarmup = false

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    @MainActor
    private func bootCoreAndDataIfNeeded() async {
        appDelegate.onTerminate = { [processManager] in
            processManager.stopSynchronously()
        }
        appDelegate.menuBarController.configure(with: pomodoroVM)

        if !processManager.state.isConnected {
            do {
                let client = try await processManager.start()
                libraryVM.configure(client: client)
                await libraryVM.loadAll()
                NSApplication.shared.appearance = SettingsViewModel.resolvedAppearance(
                    for: libraryVM.preferences.colorMode
                )
                pomodoroVM.soundEnabled = libraryVM.preferences.soundEnabled
            } catch {
                // Error state is reflected in `processManager.state`.
            }
        } else if libraryVM.decks.isEmpty && !libraryVM.isLoading {
            await libraryVM.loadAll()
        }

        if !didScheduleWebKitWarmup {
            didScheduleWebKitWarmup = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                WebKitPrewarmer.warmUp()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                processManager: processManager,
                libraryVM: libraryVM,
                pomodoroVM: pomodoroVM,
                grapherVM: grapherVM
            )
            .frame(minWidth: 960, minHeight: 620)
            .task {
                await bootCoreAndDataIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await bootCoreAndDataIfNeeded()
                }
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Import...") {
                    libraryVM.requestedImportExportTab = .import
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!processManager.state.isConnected)

                Button("Export...") {
                    libraryVM.requestedImportExportTab = .export
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!processManager.state.isConnected || libraryVM.decks.isEmpty)
            }
        }

        Settings {
            SettingsView(libraryVM: libraryVM, processManager: processManager)
        }
    }
}
