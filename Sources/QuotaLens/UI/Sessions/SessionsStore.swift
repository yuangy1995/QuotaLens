// QuotaLens 会话页面状态管理中枢 (SessionsStore)

import Foundation
import SwiftUI
import Combine

@MainActor
public final class SessionsStore: ObservableObject {
    @Published public var sessions: [CodexSessionDTO] = []
    @Published public var selectedSessionId: String? = nil {
        didSet {
            guard oldValue != selectedSessionId else { return }
            Task { await loadSelectedSessionDetail() }
        }
    }
    @Published public var selectedDetail: CodexSessionDetailDTO? = nil
    @Published public var searchText: String = "" {
        didSet {
            debounceSearch()
        }
    }
    @Published public var sortOption: SessionSort = .lastActivityDesc {
        didSet {
            Task { await reloadSessions() }
        }
    }
    @Published public var isLoading: Bool = false
    @Published public var isLoadingDetail: Bool = false
    @Published public var errorMessage: String? = nil

    private let facade: UsageQueryFacade
    private var searchCancellable: Task<Void, Never>?

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public func reloadSessions() async {
        isLoading = true
        errorMessage = nil
        do {
            let list = try await facade.getSessions(
                sort: sortOption,
                search: searchText.isEmpty ? nil : searchText,
                limit: 100
            )
            self.sessions = list
            if selectedSessionId == nil, let first = list.first {
                self.selectedSessionId = first.sessionId
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    public func loadSelectedSessionDetail() async {
        guard let sid = selectedSessionId else {
            selectedDetail = nil
            return
        }
        isLoadingDetail = true
        do {
            self.selectedDetail = try await facade.getSessionDetail(sessionId: sid)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoadingDetail = false
    }

    private func debounceSearch() {
        searchCancellable?.cancel()
        searchCancellable = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000) // 250ms
            } catch {
                return
            }
            await reloadSessions()
        }
    }
}
