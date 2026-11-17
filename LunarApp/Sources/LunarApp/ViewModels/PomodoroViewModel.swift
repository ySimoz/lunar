import AppKit
import Foundation
import Observation
import UserNotifications

/// Active interval type for the Pomodoro focus clock.
public enum PomodoroPhase: String, CaseIterable, Identifiable, Sendable {
    case focus
    case shortBreak
    case longBreak

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }
}

/// Wall-clock `targetEndTime` Pomodoro state machine with wake reconciliation,
/// 4-focus-to-long-break cycling, audio chimes, and bundle-safe notifications.
@Observable
@MainActor
public final class PomodoroViewModel {
    public private(set) var mode: PomodoroPhase = .focus {
        didSet {
            if mode != oldValue { onStatusChange?() }
        }
    }
    public var focusMinutes: Int = 25 {
        didSet {
            let clamped = max(1, min(120, focusMinutes))
            if focusMinutes != clamped {
                focusMinutes = clamped
                return
            }
            if mode == .focus && !isRunning {
                remainingSeconds = focusMinutes * 60
            }
        }
    }
    public var shortBreakMinutes: Int = 5 {
        didSet {
            let clamped = max(1, min(60, shortBreakMinutes))
            if shortBreakMinutes != clamped {
                shortBreakMinutes = clamped
                return
            }
            if mode == .shortBreak && !isRunning {
                remainingSeconds = shortBreakMinutes * 60
            }
        }
    }
    public var longBreakMinutes: Int = 15 {
        didSet {
            let clamped = max(1, min(90, longBreakMinutes))
            if longBreakMinutes != clamped {
                longBreakMinutes = clamped
                return
            }
            if mode == .longBreak && !isRunning {
                remainingSeconds = longBreakMinutes * 60
            }
        }
    }

    public private(set) var isRunning: Bool = false {
        didSet {
            if isRunning != oldValue { onStatusChange?() }
        }
    }
    public private(set) var targetEndTime: Date?
    public private(set) var remainingSeconds: Int = 25 * 60 {
        didSet {
            if remainingSeconds != oldValue { onStatusChange?() }
        }
    }
    public private(set) var completedSessions: Int = 0

    public var soundEnabled: Bool = true
    public var autoStartBreaks: Bool = false
    public var onStatusChange: (() -> Void)?

    private let nowProvider: @Sendable () -> Date
    private let audioPlayer: any AudioCuePlaying
    private let wakeToken = WakeObserverToken()

    public init(
        soundEnabled: Bool = true,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        audioPlayer: any AudioCuePlaying = AudioCueManager.shared,
        observeWakeNotifications: Bool = Bundle.main.bundleURL.pathExtension == "app"
    ) {
        self.soundEnabled = soundEnabled
        self.nowProvider = nowProvider
        self.audioPlayer = audioPlayer

        if observeWakeNotifications {
            self.wakeToken.observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reconcile()
                }
            }
        }
    }

    deinit {
        wakeToken.invalidate()
    }

    // MARK: - Computed Metrics

    public var targetSeconds: Int {
        switch mode {
        case .focus: focusMinutes * 60
        case .shortBreak: shortBreakMinutes * 60
        case .longBreak: longBreakMinutes * 60
        }
    }

    public var progressFraction: Double {
        let total = max(1, targetSeconds)
        let elapsed = Double(total - remainingSeconds)
        return min(1.0, max(0.0, elapsed / Double(total)))
    }

    public var formattedTime: String {
        let m = max(0, remainingSeconds) / 60
        let s = max(0, remainingSeconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Controls

    public func togglePlay() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    public func start() {
        let now = nowProvider()
        let duration = remainingSeconds > 0 ? remainingSeconds : targetSeconds
        remainingSeconds = duration
        targetEndTime = now.addingTimeInterval(TimeInterval(duration))
        isRunning = true
        audioPlayer.play(.flip, enabled: soundEnabled)
        requestNotificationPermissionIfBundled()
        startTicker()
    }

    public func pause() {
        reconcile(at: nowProvider())
        isRunning = false
        targetEndTime = nil
        stopTicker()
    }

    public func reset() {
        isRunning = false
        targetEndTime = nil
        remainingSeconds = targetSeconds
        stopTicker()
    }

    public func switchMode(_ newMode: PomodoroPhase) {
        mode = newMode
        isRunning = false
        targetEndTime = nil
        remainingSeconds = targetSeconds
        stopTicker()
    }

    public func skip() {
        isRunning = false
        targetEndTime = nil
        stopTicker()
        if mode == .focus {
            mode = .shortBreak
        } else {
            mode = .focus
        }
        remainingSeconds = targetSeconds
    }

    /// Reconciles remaining seconds from `targetEndTime` against wall-clock time.
    public func reconcile(at now: Date? = nil) {
        guard isRunning, let endTime = targetEndTime else { return }
        let current = now ?? nowProvider()
        let secondsLeft = Int(ceil(endTime.timeIntervalSince(current)))
        if secondsLeft <= 0 {
            completeInterval(at: current)
        } else {
            remainingSeconds = secondsLeft
        }
    }

    // MARK: - Private Cycle Logic

    private func completeInterval(at now: Date) {
        let finishedMode = mode
        audioPlayer.play(.chime, enabled: soundEnabled)
        sendCompletionNotificationIfBundled(for: finishedMode)

        if finishedMode == .focus {
            completedSessions += 1
            let nextMode: PomodoroPhase = (completedSessions % 4 == 0) ? .longBreak : .shortBreak
            mode = nextMode
            let nextDuration = targetSeconds
            remainingSeconds = nextDuration
            if autoStartBreaks {
                isRunning = true
                targetEndTime = now.addingTimeInterval(TimeInterval(nextDuration))
                startTicker()
            } else {
                isRunning = false
                targetEndTime = nil
                stopTicker()
            }
        } else {
            mode = .focus
            remainingSeconds = targetSeconds
            isRunning = false
            targetEndTime = nil
            stopTicker()
        }
    }

    private func startTicker() {
        stopTicker()
        wakeToken.tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.isRunning else { break }
                self.reconcile()
            }
        }
    }

    private func stopTicker() {
        wakeToken.tickTask?.cancel()
        wakeToken.tickTask = nil
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermissionIfBundled() {
        guard isBundledApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendCompletionNotificationIfBundled(for finishedMode: PomodoroPhase) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = finishedMode == .focus ? "Focus Complete" : "Break Finished"
        content.body = finishedMode == .focus
            ? "Time for a short break."
            : "Ready for the next focus interval."
        let request = UNNotificationRequest(
            identifier: "lunar-pomodoro-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private final class WakeObserverToken: @unchecked Sendable {
    var observer: NSObjectProtocol?
    var tickTask: Task<Void, Never>?

    func invalidate() {
        tickTask?.cancel()
        tickTask = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }
}
