import Foundation

public struct QuotaRefreshState: Equatable {
    public private(set) var snapshot: QuotaSnapshot?
    public private(set) var isRefreshing: Bool
    public private(set) var errorMessage: String?

    public init(snapshot: QuotaSnapshot? = nil, isRefreshing: Bool = false, errorMessage: String? = nil) {
        self.snapshot = snapshot
        self.isRefreshing = isRefreshing
        self.errorMessage = errorMessage
    }

    public mutating func beginRefresh() {
        isRefreshing = true
        errorMessage = nil
    }

    public mutating func finishRefresh(with result: Result<QuotaSnapshot, Error>) {
        isRefreshing = false
        switch result {
        case .success(let newSnapshot):
            snapshot = newSnapshot
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
