import Foundation

public enum KimiCodeBinaryResolver {
    public static func resolve(
        overridePath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let kimiCodeHome = environment["KIMI_CODE_HOME"]
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code").path

        let candidates = [
            "\(kimiCodeHome)/bin/kimi",
            "/usr/local/bin/kimi",
            "/opt/homebrew/bin/kimi"
        ]

        return try resolve(
            overridePath: overridePath,
            candidates: candidates,
            fileManager: fileManager,
            environment: environment
        )
    }

    public static func resolve(
        overridePath: String? = nil,
        candidates: [String],
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let overridePath = overridePath, !overridePath.isEmpty, fileManager.isExecutableFile(atPath: overridePath) {
            return URL(fileURLWithPath: overridePath)
        }

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathValue = environment["PATH"], !pathValue.isEmpty {
            return URL(fileURLWithPath: "/usr/bin/env")
        }

        throw KimiCodeError.binaryNotFound
    }

    public static func launchArguments(for executableURL: URL) -> [String] {
        if executableURL.lastPathComponent == "env" {
            return ["kimi"]
        }
        return []
    }

    public static func launchEnvironment(
        for executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var launchEnvironment = environment
        let inheritedPaths = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)

        var preferredPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        if executableURL.lastPathComponent != "env" {
            preferredPaths.insert(executableURL.deletingLastPathComponent().path, at: 0)
        }

        launchEnvironment["PATH"] = (preferredPaths + inheritedPaths).reduce(into: [String]()) { paths, path in
            if !path.isEmpty && !paths.contains(path) {
                paths.append(path)
            }
        }.joined(separator: ":")
        return launchEnvironment
    }
}
