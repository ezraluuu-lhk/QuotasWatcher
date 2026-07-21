import Foundation
@testable import QuotasWatcherCore

struct FakeClock: KimiClock {
    var now: Date
    var sleepHandler: (@Sendable (TimeInterval) async throws -> Void)?

    init(now: Date, sleepHandler: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.now = now
        self.sleepHandler = sleepHandler
    }

    func sleep(_ interval: TimeInterval) async throws {
        if let sleepHandler = sleepHandler {
            try await sleepHandler(interval)
        } else {
            try await Task.sleep(nanoseconds: 1_000)
        }
    }
}

struct FakeNetworkSession: KimiNetworkSession {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

struct FailingNetworkSession: KimiNetworkSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw KimiCodeError.usageTransportFailed("unexpected network request")
    }
}

/// Thread-safe counter for assertions inside @Sendable fake handlers.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

/// Thread-safe recorder for values produced inside @Sendable fake handlers.
final class LockedRecorder<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}

actor FakeLockCoordinator: KimiLockCoordinator {
    enum Behavior {
        case succeed
        case fail
        /// Simulates a peer holding the lock indefinitely: the acquisition
        /// waits until the calling task is cancelled, then propagates raw
        /// `CancellationError` like a generic lock implementation would.
        case blockUntilCancelled
    }

    var behavior: Behavior = .succeed
    /// Runs synchronously inside `acquireLock` before the result is returned,
    /// letting tests rotate the credential file deterministically while the
    /// provider believes a peer held or released the lock.
    var onAcquire: (@Sendable (URL) -> Void)?
    var acquiredLocks: Set<URL> = []
    var releasedLocks: Set<URL> = []
    var touchedLocks: [URL] = []
    var acquireCallCount = 0

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func setOnAcquire(_ handler: (@Sendable (URL) -> Void)?) {
        onAcquire = handler
    }

    func acquireLock(at sentinelURL: URL, timeout: TimeInterval) async throws -> Bool {
        acquireCallCount += 1
        onAcquire?(sentinelURL)
        switch behavior {
        case .succeed:
            acquiredLocks.insert(sentinelURL)
            return true
        case .fail:
            return false
        case .blockUntilCancelled:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw CancellationError()
        }
    }

    func releaseLock(at sentinelURL: URL) async {
        releasedLocks.insert(sentinelURL)
        acquiredLocks.remove(sentinelURL)
    }

    func touchLock(at sentinelURL: URL) async {
        touchedLocks.append(sentinelURL)
    }

    func isAcquired(_ sentinelURL: URL) -> Bool {
        acquiredLocks.contains(sentinelURL)
    }

    func isReleased(_ sentinelURL: URL) -> Bool {
        releasedLocks.contains(sentinelURL)
    }
}

struct FakeConfigurationResolver: KimiConfigurationResolving {
    let info: KimiManagedProviderInfo

    func resolve(
        overrideBinaryPath: String?,
        fileManager: FileManager,
        environment: [String: String],
        processLauncher: KimiProcessLaunching
    ) async throws -> KimiManagedProviderInfo {
        info
    }
}

struct FakeCredentialProvider: KimiOAuthCredentialResolving {
    let credential: KimiOAuthCredential

    func validCredential(for info: KimiManagedProviderInfo) async throws -> KimiOAuthCredential {
        credential
    }
}

struct FakeProcessLauncher: KimiProcessLaunching {
    let result: KimiProcessResult

    init(result: KimiProcessResult = KimiProcessResult(exitCode: 0, stdout: Data(), stderr: Data())) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> KimiProcessResult {
        result
    }
}

/// Records how the process would have been launched so tests can assert the
/// binary, arguments, and sanitized environment without spawning anything.
final class CapturingProcessLauncher: KimiProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval)] = []
    var result: KimiProcessResult
    var error: Error?

    init(result: KimiProcessResult = KimiProcessResult(exitCode: 0, stdout: Data(), stderr: Data())) {
        self.result = result
    }

    var recorded: [(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    private func record(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        lock.lock()
        invocations.append((executableURL, arguments, environment, timeout))
        lock.unlock()
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> KimiProcessResult {
        record(executableURL: executableURL, arguments: arguments, environment: environment, timeout: timeout)
        if let error { throw error }
        return result
    }
}

func makeHTTPResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}
