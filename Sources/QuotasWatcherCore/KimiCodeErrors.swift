import Foundation

public enum KimiCodeError: LocalizedError, Equatable {
    case binaryNotFound
    case launchFailed(String)
    case providerListFailed(String)
    case providerListMalformed(String)
    case managedProviderNotFound
    case unsupportedCredentialBackend(String)
    case credentialNotFound
    case credentialMalformed(String)
    case tokenRefreshRequired
    case tokenRefreshFailed(String)
    case tokenRevoked
    case usageRequestFailed(Int)
    case usageTransportFailed(String)
    case usageMalformed(String)
    case usageInvalidPayload(String)
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Kimi Code binary was not found."
        case .launchFailed(let message):
            return "Failed to launch Kimi Code: \(message)"
        case .providerListFailed(let message):
            return "Failed to read Kimi provider list: \(message)"
        case .providerListMalformed(let message):
            return "Kimi provider list is malformed: \(message)"
        case .managedProviderNotFound:
            return "Kimi managed provider was not found. Run `kimi login` to authenticate."
        case .unsupportedCredentialBackend(let backend):
            return "Unsupported Kimi credential backend: \(backend)"
        case .credentialNotFound:
            return "Kimi credentials were not found. Run `kimi login` to authenticate."
        case .credentialMalformed(let message):
            return "Kimi credentials are malformed: \(message)"
        case .tokenRefreshRequired:
            return "Kimi access token is expired and refresh is required."
        case .tokenRefreshFailed(let message):
            return "Failed to refresh Kimi token: \(message)"
        case .tokenRevoked:
            return "Kimi session has expired or been revoked. Run `kimi login` to authenticate again."
        case .usageRequestFailed(let status):
            return "Kimi usage request failed with HTTP \(status)."
        case .usageTransportFailed(let message):
            return "Kimi usage request failed: \(message)"
        case .usageMalformed(let message):
            return "Kimi usage response is malformed: \(message)"
        case .usageInvalidPayload(let message):
            return "Kimi usage payload is invalid: \(message)"
        case .timeout:
            return "Kimi Code did not respond before the timeout."
        case .cancelled:
            return "Kimi refresh was cancelled."
        }
    }
}
