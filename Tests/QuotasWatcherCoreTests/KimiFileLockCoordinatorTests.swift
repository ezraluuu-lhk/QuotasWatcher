import XCTest
@testable import QuotasWatcherCore

final class KimiFileLockCoordinatorTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    func testAcquireCreatesLockDirectory() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)
        let lockURL = sentinelURL.appendingPathExtension("lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        await coordinator.releaseLock(at: sentinelURL)
    }

    func testAcquireWaitsForOwnedLockThenReleases() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")

        let first = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(first)

        // A second coordinator should time out because the lock is held.
        let secondCoordinator = KimiFileLockCoordinator()
        let second = try await secondCoordinator.acquireLock(at: sentinelURL, timeout: 0.1)
        XCTAssertFalse(second)

        await coordinator.releaseLock(at: sentinelURL)

        // After release, re-acquisition succeeds.
        let third = try await secondCoordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(third)
        await secondCoordinator.releaseLock(at: sentinelURL)
    }

    func testReleasesOnlyOwnedLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        // Create a lock directory manually to simulate another owner.
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        await coordinator.releaseLock(at: sentinelURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testHeartbeatUpdatesLockMtime() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)

        let firstAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let firstMtime = firstAttributes[.modificationDate] as! Date

        // Wait for the heartbeat to update the lock.
        try await Task.sleep(nanoseconds: 3_500_000_000)

        let secondAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let secondMtime = secondAttributes[.modificationDate] as! Date
        XCTAssertGreaterThan(secondMtime, firstMtime)

        await coordinator.releaseLock(at: sentinelURL)
    }

    func testStaleLockIsBroken() async throws {
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        // Create an old lock directory to simulate a stale lock.
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        let oldDate = Date().addingTimeInterval(-10)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: lockURL.path)

        let coordinator = KimiFileLockCoordinator()
        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)
        await coordinator.releaseLock(at: sentinelURL)
    }

    func testReleaseRemovesOwnLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)

        await coordinator.releaseLock(at: sentinelURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lockURL.path),
            "release must remove the lock directory this process acquired"
        )
    }

    func testReleaseDoesNotRemoveReplacedPeerLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)

        // The held lock is replaced by a peer before release, without any
        // heartbeat in between: release must detect the identity change on its
        // own and leave the replacement in place.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        await coordinator.releaseLock(at: sentinelURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "release must not remove the replacement lock"
        )
    }

    func testTouchAndReleaseDoNotTouchReplacedPeerLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)

        // A peer steals the lock: our directory is deleted and replaced by a
        // fresh one with a demonstrably different acquisition identity.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let peerMtime = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: peerMtime], ofItemAtPath: lockURL.path)

        // Heartbeat/touch must not update the replacement's mtime.
        await coordinator.touchLock(at: sentinelURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let mtime = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThan(
            Date().timeIntervalSince(mtime),
            30,
            "touch must not update the replacement lock's mtime"
        )

        // Release must not remove the replacement.
        await coordinator.releaseLock(at: sentinelURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "release must not remove the replacement lock"
        )
    }

    func testRunningHeartbeatStopsTouchingReplacedLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 1)
        XCTAssertTrue(acquired)

        // Replace the held lock with a peer's directory after acquisition.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let peerMtime = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: peerMtime], ofItemAtPath: lockURL.path)

        // Let at least one heartbeat fire (interval is 2.5 seconds).
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let mtime = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThan(
            Date().timeIntervalSince(mtime),
            30,
            "heartbeat must not update the replacement lock's mtime"
        )

        await coordinator.releaseLock(at: sentinelURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testLivePeerLockIsNotRemovedOnAcquireTimeout() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        // A live peer holds the lock (fresh mtime, inside the stale window).
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        let acquired = try await coordinator.acquireLock(at: sentinelURL, timeout: 0.3)
        XCTAssertFalse(acquired)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "a live peer lock must survive our failed acquisition"
        )
    }

    func testCancellationWhileWaitingForPeerLockThrowsCancelledAndPreservesPeerLock() async throws {
        let coordinator = KimiFileLockCoordinator()
        let sentinelURL = tempDirectory.appendingPathComponent("oauth").appendingPathComponent("kimi-code")
        let lockURL = sentinelURL.appendingPathExtension("lock")

        // A live peer owns the lock, so acquisition waits.
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)

        let task = Task {
            try await coordinator.acquireLock(at: sentinelURL, timeout: 30)
        }
        // Give the acquisition loop time to start polling.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .cancelled)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "cancellation must not remove the peer lock"
        )
    }
}
