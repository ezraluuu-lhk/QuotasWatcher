import XCTest
@testable import QuotasWatcherCore

final class KimiCodeConfigurationTests: XCTestCase {
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

    func testParsesManagedProviderFromArray() throws {
        let json = """
        {
          "providers": [
            {
              "id": "custom:other",
              "baseUrl": "https://example.com",
              "oauth": { "key": "other" }
            },
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": { "key": "kimi-code" }
            }
          ]
        }
        """
        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: credentialsDir.appendingPathComponent("kimi-code.json").path, contents: Data(), attributes: nil)

        let info = try KimiCodeConfiguration.parseProviderList(
            Data(json.utf8),
            fileManager: FileManager.default,
            environment: ["KIMI_CODE_HOME": tempDirectory.path]
        )
        XCTAssertEqual(info.baseURL.absoluteString, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        XCTAssertEqual(info.oauthKey, "kimi-code")
    }

    func testParsesManagedProviderFromDictionary() throws {
        let json = """
        {
          "providers": {
            "managed:kimi-code": {
              "type": "kimi",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": {
                "storage": "file",
                "key": "oauth/kimi-code"
              }
            }
          }
        }
        """
        let credentialsDir = tempDirectory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentialsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: credentialsDir.appendingPathComponent("kimi-code.json").path, contents: Data(), attributes: nil)

        let info = try KimiCodeConfiguration.parseProviderList(
            Data(json.utf8),
            fileManager: FileManager.default,
            environment: ["KIMI_CODE_HOME": tempDirectory.path]
        )
        XCTAssertEqual(info.baseURL.absoluteString, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        XCTAssertEqual(info.oauthKey, "oauth/kimi-code")
    }

    func testIgnoresCustomProviders() throws {
        let json = """
        {
          "providers": [
            { "id": "custom:something", "baseUrl": "https://custom.example.com" }
          ]
        }
        """
        XCTAssertThrowsError(try KimiCodeConfiguration.parseProviderList(Data(json.utf8))) { error in
            XCTAssertEqual((error as? KimiCodeError), .managedProviderNotFound)
        }
    }

    func testMissingOAuthRefUsesOfficialDefaultSlot() throws {
        // No `oauth` object: the official toolkit defaults the key to
        // `oauth/kimi-code`, which resolves to storage name `kimi-code`.
        let json = """
        {
          "providers": [
            { "id": "managed:kimi-code", "baseUrl": "https://api.kimi.com/coding/v1" }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(
            Data(json.utf8),
            environment: ["KIMI_CODE_HOME": tempDirectory.path]
        )
        XCTAssertEqual(info.baseURL.absoluteString, "https://api.kimi.com/coding/v1")
        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        XCTAssertEqual(info.oauthKey, "oauth/kimi-code")
        XCTAssertNil(info.oauthHost)
    }

    func testUnsupportedStorageBackendYieldsError() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": { "storage": "keyring" }
            }
          ]
        }
        """
        XCTAssertThrowsError(try KimiCodeConfiguration.parseProviderList(Data(json.utf8))) { error in
            XCTAssertEqual((error as? KimiCodeError), .unsupportedCredentialBackend("keyring"))
        }
    }

    func testScopedOAuthKeyResolvesStorageName() throws {
        // Production shape for a custom OAuth host: the toolkit persists a
        // scoped key `oauth/kimi-code-env-<sha256-16>` plus `oauthHost`.
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": {
                "storage": "file",
                "key": "oauth/kimi-code-env-0123456789abcdef",
                "oauthHost": "https://auth.example.com"
              }
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.credentialStorageName, "kimi-code-env-0123456789abcdef")
        XCTAssertEqual(info.oauthKey, "oauth/kimi-code-env-0123456789abcdef")
        XCTAssertEqual(info.oauthHost, "https://auth.example.com")
    }

    func testLegacyHostFieldIsOnlySecondaryFallback() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": { "key": "oauth/kimi-code", "host": "https://legacy-auth.example.com" }
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        XCTAssertEqual(info.oauthHost, "https://legacy-auth.example.com")
    }

    func testOAuthHostFieldWinsOverLegacyHost() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": {
                "key": "oauth/kimi-code",
                "oauthHost": "https://auth.example.com",
                "host": "https://legacy-auth.example.com"
              }
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.oauthHost, "https://auth.example.com")
    }

    func testBareKimiCodeKeyResolvesDefaultSlot() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": { "key": "kimi-code" }
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        XCTAssertEqual(info.oauthKey, "kimi-code")
    }

    func testSafeBareOAuthKeyMapsToItself() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://api.kimi.com/coding/v1",
              "oauth": { "key": "team-alpha" }
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.credentialStorageName, "team-alpha")
        XCTAssertEqual(info.oauthKey, "team-alpha")
    }

    func testInvalidOAuthKeysAreRejected() throws {
        let invalidKeys = [
            "../escape",                 // traversal
            "oauth/../escape",           // scoped traversal
            "oauth/",                    // empty scoped name
            ".hidden",                   // leading dot
            "oauth/.hidden",             // scoped leading dot
            "a/b",                       // slash outside the oauth/ prefix
            "oauth/a/b",                 // nested slash inside scoped name
            "with\\backslash",           // backslash
            "with:colon"                 // colon
        ]

        for key in invalidKeys {
            let payload: [String: Any] = [
                "providers": [
                    [
                        "id": "managed:kimi-code",
                        "baseUrl": "https://api.kimi.com/coding/v1",
                        "oauth": ["key": key]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(
                try KimiCodeConfiguration.parseProviderList(data),
                "expected key \(key.debugDescription) to be rejected"
            ) { error in
                guard case .providerListMalformed = error as? KimiCodeError else {
                    return XCTFail("Unexpected error \(error) for key \(key.debugDescription)")
                }
            }
        }
    }

    func testScopedStorageNameValidationMatchesOfficialRules() throws {
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: nil), "kimi-code")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: ""), "kimi-code")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "kimi-code"), "kimi-code")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "oauth/kimi-code"), "kimi-code")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "oauth/kimi-code-env-abcdef0123456789"), "kimi-code-env-abcdef0123456789")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "oauth/team"), "team")
        XCTAssertEqual(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "team"), "team")
        XCTAssertThrowsError(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "oauth/"))
        XCTAssertThrowsError(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "oauth/../x"))
        XCTAssertThrowsError(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "../x"))
        XCTAssertThrowsError(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: ".x"))
        XCTAssertThrowsError(try KimiCodeConfiguration.credentialStorageName(forOAuthKey: "a/b"))
    }

    func testCustomBaseURLAndDefaultOAuthHost() throws {
        let json = """
        {
          "providers": [
            {
              "id": "managed:kimi-code",
              "baseUrl": "https://custom.kimi.example.com/v1"
            }
          ]
        }
        """
        let info = try KimiCodeConfiguration.parseProviderList(Data(json.utf8))
        XCTAssertEqual(info.baseURL.absoluteString, "https://custom.kimi.example.com/v1")
        XCTAssertNil(info.oauthHost)
    }

    func testMalformedTopLevelObject() throws {
        let json = "not json"
        XCTAssertThrowsError(try KimiCodeConfiguration.parseProviderList(Data(json.utf8))) { error in
            XCTAssertEqual((error as? KimiCodeError), .providerListMalformed("top-level object is not a dictionary"))
        }
    }

    // MARK: - Resolve + launch environment

    func testResolvePassesSanitizedEnvironmentAndArguments() async throws {
        let binary = tempDirectory.appendingPathComponent("kimi")
        FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let json = """
        {
          "providers": [
            { "id": "managed:kimi-code", "baseUrl": "https://api.kimi.com/coding/v1", "oauth": { "key": "kimi-code" } }
          ]
        }
        """
        let launcher = CapturingProcessLauncher(
            result: KimiProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        )

        let info = try await KimiCodeConfiguration.resolve(
            overrideBinaryPath: binary.path,
            fileManager: FileManager.default,
            environment: ["PATH": "/custom/bin", "HOME": "/tmp/home"],
            processLauncher: launcher
        )

        XCTAssertEqual(info.credentialStorageName, "kimi-code")
        let invocations = launcher.recorded
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.executableURL.path, binary.path)
        XCTAssertEqual(invocations.first?.arguments, ["provider", "list", "--json"])
        let path = invocations.first?.environment["PATH"] ?? ""
        // The binary's own directory leads, followed by the standard system
        // directories, then the inherited PATH, deduplicated.
        XCTAssertTrue(path.hasPrefix("\(tempDirectory.path):"), "unexpected PATH \(path)")
        XCTAssertTrue(path.contains("/usr/bin"), "unexpected PATH \(path)")
        XCTAssertTrue(path.contains("/custom/bin"), "unexpected PATH \(path)")
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/custom/bin" }.count, 1)
        XCTAssertEqual(invocations.first?.environment["HOME"], "/tmp/home")
    }

    func testResolvePropagatesLauncherError() async {
        let binary = tempDirectory.appendingPathComponent("kimi")
        FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let launcher = CapturingProcessLauncher()
        launcher.error = KimiCodeError.timeout

        do {
            _ = try await KimiCodeConfiguration.resolve(
                overrideBinaryPath: binary.path,
                fileManager: FileManager.default,
                environment: [:],
                processLauncher: launcher
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .timeout)
        }
    }

    func testResolveFailsOnNonZeroExitWithoutLoggingStdout() async {
        let binary = tempDirectory.appendingPathComponent("kimi")
        FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let launcher = CapturingProcessLauncher(
            result: KimiProcessResult(
                exitCode: 1,
                stdout: Data(#"{"providers":[{"id":"custom:x","apiKey":"secret-value"}]}"#.utf8),
                stderr: Data("boom".utf8)
            )
        )

        do {
            _ = try await KimiCodeConfiguration.resolve(
                overrideBinaryPath: binary.path,
                fileManager: FileManager.default,
                environment: [:],
                processLauncher: launcher
            )
            XCTFail("Expected provider list failure")
        } catch {
            guard case .providerListFailed(let message) = error as? KimiCodeError else {
                return XCTFail("Unexpected error \(error)")
            }
            // The error carries the stderr diagnostic only, never stdout JSON.
            XCTAssertEqual(message, "boom")
            XCTAssertFalse(error.localizedDescription.contains("secret-value"))
        }
    }

    // MARK: - Process launcher (real processes, no network)

    func testLaunchFailureYieldsTypedError() async {
        let launcher = KimiProcessLauncher()
        do {
            _ = try await launcher.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/kimi-binary"),
                arguments: [],
                environment: [:],
                timeout: 5
            )
            XCTFail("Expected launch failure")
        } catch {
            guard case .launchFailed = error as? KimiCodeError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testProcessTimeoutTerminatesChild() async {
        let launcher = KimiProcessLauncher()
        do {
            _ = try await launcher.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: [:],
                timeout: 0.2
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .timeout)
        }
    }

    func testProcessCancellationTerminatesChild() async {
        let launcher = KimiProcessLauncher()
        let task = Task {
            try await launcher.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: [:],
                timeout: 30
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual((error as? KimiCodeError), .cancelled)
        }
    }

    func testProcessCapturesStdoutAndExitCode() async throws {
        let launcher = KimiProcessLauncher()
        let result = try await launcher.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            environment: [:],
            timeout: 5
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testProcessCapturesLargeFastOutputWithoutTruncation() async throws {
        // Deterministic payloads well past the 64 KB pipe capacity, so both
        // streams span many pipe reads. The child (cat) exits immediately,
        // racing the readability callbacks; the final EOF drain must still
        // deliver every byte, unaltered and in order.
        var stdoutPayload = Data()
        for index in 0..<20_000 {
            stdoutPayload.append(contentsOf: "stdout-line-\(index)\n".utf8)
        }
        var stderrPayload = Data()
        for index in 0..<12_000 {
            stderrPayload.append(contentsOf: "stderr-line-\(index)\n".utf8)
        }
        XCTAssertGreaterThan(stdoutPayload.count, 65_536)
        XCTAssertGreaterThan(stderrPayload.count, 65_536)

        let stdoutURL = tempDirectory.appendingPathComponent("stdout-payload.bin")
        let stderrURL = tempDirectory.appendingPathComponent("stderr-payload.bin")
        try stdoutPayload.write(to: stdoutURL)
        try stderrPayload.write(to: stderrURL)

        let launcher = KimiProcessLauncher()
        let result = try await launcher.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/cat \"$1\"; /bin/cat \"$2\" >&2",
                "sh",
                stdoutURL.path,
                stderrURL.path
            ],
            environment: [:],
            timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, stdoutPayload)
        XCTAssertEqual(result.stderr, stderrPayload)
    }
}
