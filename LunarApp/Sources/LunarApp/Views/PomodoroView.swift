import AppKit
import SwiftUI

/// Calm Ring Clock Pomodoro view with `.monospacedDigit()` countdown
/// and an instant inline monochrome duration/alert settings panel.
public struct PomodoroView: View {
    @Bindable var pomodoroVM: PomodoroViewModel

    @AppStorage("lunar.showPomodoroInMenuBar") private var showPomodoroInMenuBar: Bool = true
    @State private var showSettingsPanel = false
    @State private var hitTargets = PanelHitTargets()
    @Environment(\.colorScheme) private var colorScheme

    public init(pomodoroVM: PomodoroViewModel) {
        self.pomodoroVM = pomodoroVM
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Keep header outside ScrollView so hover and clicks never stall on NSScrollView tracking.
            HStack {
                LunarSegmentedControl(
                    selection: Binding(
                        get: { pomodoroVM.mode },
                        set: { pomodoroVM.switchMode($0) }
                    ),
                    options: PomodoroPhase.allCases.map { ($0, $0.displayName) }
                )

                Spacer()

                Button {
                    showSettingsPanel.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(MonochromeGlassButtonStyle(compact: true))
                .background(AnchorView { hitTargets.buttonView = $0 })
                .help("Timer Settings")
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, LunarTokens.space6)
            .padding(.top, LunarTokens.space6)
            .padding(.bottom, LunarTokens.space4)

            ScrollView {
                VStack(spacing: LunarTokens.space6) {
                    VStack(spacing: LunarTokens.space6) {
                        ZStack {
                            Circle()
                                .stroke(LunarTokens.neutralTrack, lineWidth: 6)

                            Circle()
                                .trim(from: 0, to: pomodoroVM.progressFraction)
                                .stroke(
                                    LunarTokens.neutralHighlight,
                                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .animation(LunarTokens.revealAnimation, value: pomodoroVM.progressFraction)

                            VStack(spacing: LunarTokens.space2) {
                                Text(pomodoroVM.mode.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)

                                Text(pomodoroVM.formattedTime)
                                    .font(.system(size: 46, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)

                                Text("Completed: \(pomodoroVM.completedSessions)")
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 236, height: 236)

                        HStack(spacing: LunarTokens.space3) {
                            Button {
                                pomodoroVM.reset()
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.bordered)

                            Button {
                                pomodoroVM.togglePlay()
                            } label: {
                                Label(
                                    pomodoroVM.isRunning ? "Pause" : "Start",
                                    systemImage: pomodoroVM.isRunning ? "pause.fill" : "play.fill"
                                )
                                .frame(minWidth: 96)
                            }
                            .buttonStyle(MonochromeProminentButtonStyle())

                            Button {
                                pomodoroVM.skip()
                            } label: {
                                Label("Skip", systemImage: "forward.end")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(LunarTokens.space8)
                    .frame(maxWidth: .infinity)
                    .lunarGlassCard(cornerRadius: LunarTokens.panelRadius)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, LunarTokens.space6)
                .padding(.bottom, LunarTokens.space6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if showSettingsPanel {
                HStack {
                    Spacer()
                    timerSettingsPanel
                        .background(AnchorView { hitTargets.panelView = $0 })
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, LunarTokens.space6)
                .padding(.top, 60)
            }
        }
        .onChange(of: showSettingsPanel) { _, isOpen in
            if isOpen {
                installOutsideClickMonitor()
            } else {
                hitTargets.removeMonitor()
            }
        }
        .onDisappear {
            hitTargets.removeMonitor()
        }
        .onExitCommand {
            showSettingsPanel = false
        }
    }

    private var timerSettingsPanel: some View {
        let shape = RoundedRectangle(cornerRadius: LunarTokens.cardRadius, style: .continuous)
        let fill = colorScheme == .dark ? Color(white: 0.14) : Color(white: 0.98)

        return VStack(alignment: .leading, spacing: LunarTokens.space3) {
            Text("Timer Settings")
                .font(.system(size: 13, weight: .semibold))

            Stepper("Focus: \(pomodoroVM.focusMinutes)m", value: $pomodoroVM.focusMinutes, in: 5...90, step: 5)
                .font(.system(size: 12))
                .monospacedDigit()

            Stepper("Short Break: \(pomodoroVM.shortBreakMinutes)m", value: $pomodoroVM.shortBreakMinutes, in: 1...30)
                .font(.system(size: 12))
                .monospacedDigit()

            Stepper("Long Break: \(pomodoroVM.longBreakMinutes)m", value: $pomodoroVM.longBreakMinutes, in: 5...60, step: 5)
                .font(.system(size: 12))
                .monospacedDigit()

            Divider()

            Group {
                Toggle("Show timer in menu bar", isOn: $showPomodoroInMenuBar)
                Toggle("Chime on completion", isOn: $pomodoroVM.soundEnabled)
                Toggle("Auto-start breaks", isOn: $pomodoroVM.autoStartBreaks)
            }
            .font(.system(size: 12))
            .toggleStyle(MonochromeGlassToggleStyle())
        }
        .padding(LunarTokens.space4)
        .frame(width: 260, alignment: .leading)
        .background(fill, in: shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func installOutsideClickMonitor() {
        hitTargets.removeMonitor()
        hitTargets.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard showSettingsPanel else { return event }
            let targetWindow = hitTargets.panelView?.window ?? hitTargets.buttonView?.window
            if let targetWindow, event.window !== targetWindow {
                showSettingsPanel = false
                return event
            }
            let inPanel = hitTargets.panelView.map { view in
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            } ?? false
            let inButton = hitTargets.buttonView.map { view in
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            } ?? false
            if !inPanel && !inButton {
                showSettingsPanel = false
            }
            return event
        }
    }
}

@MainActor
private final class PanelHitTargets {
    weak var buttonView: NSView?
    weak var panelView: NSView?
    nonisolated(unsafe) var monitor: Any?

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private struct AnchorView: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NonHitNSView {
        let view = NonHitNSView()
        onAttach(view)
        return view
    }

    func updateNSView(_ nsView: NonHitNSView, context: Context) {
        onAttach(nsView)
    }

    final class NonHitNSView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
