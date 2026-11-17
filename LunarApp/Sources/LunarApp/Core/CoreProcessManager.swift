import AppKit
import Foundation
import Observation

/// Errors encountered while locating, spawning, or connecting to `lunar-core`.
public enum CoreProcessError: LocalizedError, Sendable, Equatable {
    case binaryNotFound([String])
    case invalidAddress(String)
    case processExited(Int32, String)
    case startupTimeout

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            return "Could not find lunar-core binary. Searched: \(searched.joined(separator: ", "))"
        case .invalidAddress(let raw):
            return "Invalid LUNAR_CORE_ADDR value: \(raw)"
        case .processExited(let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "lunar-core exited early with status \(code)."
                : "lunar-core exited with status \(code): \(detail)"
        case .startupTimeout:
            return "Timed out waiting for lunar-core to announce its HTTP address."
        }
    }
}

/// Lifecycle state of the managed `lunar-core` daemon.
public enum CoreConnectionState: Equatable, Sendable {
    case idle
    case starting
    case connected(URL)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Spawns and manages the local `lunar-core` Go daemon, discovering its ephemeral HTTP address
/// from `LUNAR_CORE_ADDR=...` on stdout and terminating the child process cleanly on app exit.
@Observable
@MainActor
public final class CoreProcessManager {
    public private(set) var state: CoreConnectionState = .idle
    public private(set) var client: CoreClient?

    private var process: Process?
    private var inFlightStartTask: Task<CoreClient, Error>?
    private let terminationToken = TerminationToken()
    private let explicitBinaryURL: URL?
    private let explicitBaseURL: URL?
    private let databasePath: String?

    public init(
        binaryURL: URL? = nil,
        baseURL: URL? = nil,
        databasePath: String? = nil
    ) {
        self.explicitBinaryURL = binaryURL
        self.explicitBaseURL = baseURL
        self.databasePath = databasePath

        self.terminationToken.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.stopSynchronously()
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self?.stopSynchronously()
                    }
                }
            }
        }
    }

    deinit {
        terminationToken.invalidate()
    }

    /// Parses a stdout line of the form `LUNAR_CORE_ADDR=127.0.0.1:54321` into an HTTP base URL.
    public nonisolated static func parseCoreAddress(fromLine line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("LUNAR_CORE_ADDR=") else { return nil }
        let rawAddr = String(trimmed.dropFirst("LUNAR_CORE_ADDR=".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawAddr.isEmpty else { return nil }
        if rawAddr.hasPrefix("http://") || rawAddr.hasPrefix("https://") {
            return URL(string: rawAddr)
        }
        return URL(string: "http://\(rawAddr)")
    }

    /// Starts `lunar-core` (or attaches to an explicit/environment URL) and prepares `client`.
    @discardableResult
    public func start(customBinaryURL: URL? = nil) async throws -> CoreClient {
        if let client, case .connected = state {
            if let proc = process, !proc.isRunning {
                // Previous daemon exited; reset and relaunch cleanly.
                self.process = nil
                self.terminationToken.process = nil
                self.client = nil
                self.state = .idle
            } else {
                return client
            }
        }

        if let inFlightStartTask {
            return try await inFlightStartTask.value
        }

        state = .starting

        if let attachURL = resolveAttachURL() {
            let newClient = CoreClient(baseURL: attachURL)
            self.client = newClient
            self.state = .connected(attachURL)
            return newClient
        }

        let task = Task<CoreClient, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let (binaryURL, searchedPaths) = self.resolveBinaryURL(override: customBinaryURL ?? self.explicitBinaryURL)
            guard let binaryURL else {
                throw CoreProcessError.binaryNotFound(searchedPaths)
            }

            let (_, discoveredURL) = try await self.launchAndAwaitAddress(binaryURL: binaryURL)
            let newClient = CoreClient(baseURL: discoveredURL)
            self.client = newClient
            self.state = .connected(discoveredURL)
            return newClient
        }

        inFlightStartTask = task
        do {
            let startedClient = try await task.value
            inFlightStartTask = nil
            return startedClient
        } catch {
            inFlightStartTask = nil
            self.state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Cleanly shuts down the managed `lunar-core` child process.
    public func stop() async {
        inFlightStartTask?.cancel()
        inFlightStartTask = nil

        guard let proc = process else {
            client = nil
            state = .idle
            return
        }

        self.process = nil
        self.terminationToken.process = nil
        self.client = nil
        self.state = .idle

        if proc.isRunning {
            proc.terminate()
            await Task.detached {
                let deadline = Date().addingTimeInterval(1.5)
                while proc.isRunning && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
                proc.waitUntilExit()
            }.value
        }
    }

    /// Synchronous teardown used during `NSApplication.willTerminateNotification`.
    public func stopSynchronously() {
        inFlightStartTask?.cancel()
        inFlightStartTask = nil

        guard let proc = process else { return }
        self.process = nil
        self.terminationToken.process = nil
        if proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(0.75)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
            proc.waitUntilExit()
        }
    }

    // MARK: - Private Helpers

    private func resolveAttachURL() -> URL? {
        if let explicitBaseURL {
            return explicitBaseURL
        }
        let env = ProcessInfo.processInfo.environment
        if let rawURL = env["LUNAR_CORE_URL"] ?? env["LUNAR_CORE_ADDR"], !rawURL.isEmpty {
            if rawURL.hasPrefix("http://") || rawURL.hasPrefix("https://") {
                return URL(string: rawURL)
            }
            return URL(string: "http://\(rawURL)")
        }
        return nil
    }

    private func resolveBinaryURL(override: URL?) -> (URL?, [String]) {
        var candidates: [URL] = []
        if let override {
            candidates.append(override)
        }
        if let envBin = ProcessInfo.processInfo.environment["LUNAR_CORE_BIN"], !envBin.isEmpty {
            candidates.append(URL(fileURLWithPath: envBin))
        }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "lunar-core") {
            candidates.append(aux)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("lunar-core") {
            candidates.append(res)
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()

        let relativePaths = [
            "lunar-core",
            "build/debug/lunar-core",
            "build/release/lunar-core",
            "core/lunar-core",
            "../build/debug/lunar-core",
            "../core/lunar-core",
            "../../build/debug/lunar-core",
            "../../core/lunar-core",
            "../../../core/lunar-core"
        ]
        for rel in relativePaths {
            candidates.append(cwd.appendingPathComponent(rel).standardizedFileURL)
            if let execDir {
                candidates.append(execDir.appendingPathComponent(rel).standardizedFileURL)
            }
        }

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/lunar-core"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/lunar-core"))

        let fm = FileManager.default
        var searched: [String] = []
        for url in candidates {
            let path = url.path
            searched.append(path)
            if fm.isExecutableFile(atPath: path) {
                return (url, searched)
            }
        }
        return (nil, searched)
    }

    private func resolvedDatabasePath() -> String? {
        if let databasePath, !databasePath.isEmpty {
            return databasePath
        }
        if let envDB = ProcessInfo.processInfo.environment["LUNAR_DB_PATH"], !envDB.isEmpty {
            return envDB
        }
        let isDebugBundle = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
        #if DEBUG
        let useDebugDB = true
        #else
        let useDebugDB = isDebugBundle
        #endif
        if useDebugDB,
           let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
                .appendingPathComponent("Lunar-Debug", isDirectory: true)
                .appendingPathComponent("lunar.db")
                .path
        }
        return nil
    }

    private func launchAndAwaitAddress(binaryURL: URL) async throws -> (Process, URL) {
        let proc = Process()
        proc.executableURL = binaryURL

        var args = ["-addr", "127.0.0.1:0"]
        if let dbPath = resolvedDatabasePath() {
            args.append(contentsOf: ["-db", dbPath])
        }
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        self.process = proc
        self.terminationToken.process = proc

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let scanner = ProcessStartupScanner()

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                scanner.appendStderr(data)
            }
        }

        do {
            let discoveredURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                scanner.setContinuation(continuation)

                let timeoutItem = DispatchWorkItem {
                    scanner.failIfPending(with: CoreProcessError.startupTimeout)
                }
                scanner.setTimeoutItem(timeoutItem)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10, execute: timeoutItem)

                proc.terminationHandler = { finishedProc in
                    scanner.failIfPending(
                        with: CoreProcessError.processExited(
                            finishedProc.terminationStatus,
                            scanner.stderrSnapshot()
                        )
                    )
                }

                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        let status = proc.isRunning ? 0 : proc.terminationStatus
                        scanner.failIfPending(
                            with: CoreProcessError.processExited(status, scanner.stderrSnapshot())
                        )
                        return
                    }
                    if let url = scanner.appendStdoutAndScanAddress(data) {
                        scanner.succeedIfPending(with: url)
                        // Switch stdout handler to drain quietly without accumulating lines.
                        handle.readabilityHandler = { drainHandle in
                            if drainHandle.availableData.isEmpty {
                                drainHandle.readabilityHandler = nil
                            }
                        }
                    }
                }
            }

            return (proc, discoveredURL)
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            proc.terminationHandler = nil
            if self.process === proc {
                self.process = nil
                self.terminationToken.process = nil
            }
            if proc.isRunning {
                proc.terminate()
            }
            throw error
        }
    }
}

private final class ProcessStartupScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeoutItem: DispatchWorkItem?
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setTimeoutItem(_ item: DispatchWorkItem) {
        lock.lock()
        self.timeoutItem = item
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderrBuffer.append(data)
        if stderrBuffer.count > 16_384 {
            stderrBuffer.removeFirst(stderrBuffer.count - 16_384)
        }
        lock.unlock()
    }

    func stderrSnapshot() -> String {
        lock.lock()
        let text = String(data: stderrBuffer, encoding: .utf8) ?? ""
        lock.unlock()
        return text
    }

    func appendStdoutAndScanAddress(_ data: Data) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8),
               let url = CoreProcessManager.parseCoreAddress(fromLine: line) {
                return url
            }
        }
        return nil
    }

    func succeedIfPending(with url: URL) {
        lock.lock()
        guard !completed, let cont = continuation else {
            lock.unlock()
            return
        }
        completed = true
        continuation = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        lock.unlock()
        cont.resume(returning: url)
    }

    func failIfPending(with error: Error) {
        lock.lock()
        guard !completed, let cont = continuation else {
            lock.unlock()
            return
        }
        completed = true
        continuation = nil
        timeoutItem?.cancel()
        timeoutItem = nil
        lock.unlock()
        cont.resume(throwing: error)
    }
}

private final class TerminationToken: @unchecked Sendable {
    var observer: NSObjectProtocol?
    var process: Process?

    func invalidate() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
}
