import XCTest
@testable import QuotasWatcherCore

final class KimiCodeBinaryResolverTests: XCTestCase {
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

    func testOverridePathTakesPrecedence() throws {
        let override = tempDirectory.appendingPathComponent("kimi")
        FileManager.default.createFile(atPath: override.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let url = try KimiCodeBinaryResolver.resolve(
            overridePath: override.path,
            fileManager: FileManager.default,
            environment: [:]
        )
        XCTAssertEqual(url.path, override.path)
    }

    func testRespectsKIMI_CODE_HOME() throws {
        let kimiHome = tempDirectory.appendingPathComponent("kimi-home", isDirectory: true)
        let binDir = kimiHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let binary = binDir.appendingPathComponent("kimi")
        FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let url = try KimiCodeBinaryResolver.resolve(
            fileManager: FileManager.default,
            environment: ["KIMI_CODE_HOME": kimiHome.path]
        )
        XCTAssertEqual(url.path, binary.path)
    }

    func testFallsBackToPathEnvWhenNoCandidateExists() throws {
        let url = try KimiCodeBinaryResolver.resolve(
            candidates: [],
            fileManager: FileManager.default,
            environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(url.lastPathComponent, "env")
    }

    func testThrowsWhenNotFound() {
        XCTAssertThrowsError(try KimiCodeBinaryResolver.resolve(
            candidates: [],
            fileManager: FileManager.default,
            environment: [:]
        )) { error in
            XCTAssertEqual((error as? KimiCodeError), .binaryNotFound)
        }
    }

    func testLaunchArgumentsForEnv() {
        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        XCTAssertEqual(KimiCodeBinaryResolver.launchArguments(for: envURL), ["kimi"])
    }

    func testLaunchArgumentsForDirectBinary() {
        let binaryURL = URL(fileURLWithPath: "/usr/local/bin/kimi")
        XCTAssertEqual(KimiCodeBinaryResolver.launchArguments(for: binaryURL), [])
    }

    func testLaunchEnvironmentPrependsBinaryDirectory() {
        let binaryURL = URL(fileURLWithPath: "/custom/bin/kimi")
        let environment = KimiCodeBinaryResolver.launchEnvironment(
            for: binaryURL,
            environment: ["PATH": "/minimal/bin", "HOME": "/tmp/home"]
        )
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/custom/bin:") ?? false)
        XCTAssertEqual(environment["HOME"], "/tmp/home")
    }
}
