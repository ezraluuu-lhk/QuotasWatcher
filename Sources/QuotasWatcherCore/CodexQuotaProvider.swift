import Foundation

public final class CodexQuotaProvider: QuotaProvider {
    public let id: QuotaProviderID = .codex
    private let client: CodexAppServerClient

    public init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    public func fetchQuotaSnapshot() async throws -> QuotaSnapshot {
        try await client.fetchRateLimits()
    }
}
