// QuotaLens 会话页面状态管理中枢 (SessionsStore)

import Foundation
import SwiftUI
import Combine

public struct ProjectSessionGroup: Identifiable, Sendable {
    public var id: String { project }
    public let project: String
    public let displayName: String
    public let sessions: [CodexSessionDTO]
    public let totalTokens: Int64
    public let totalCost: MoneyNanoUSD
    public let legacyAggregateCost: MoneyNanoUSD
    public let sessionCount: Int
}

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
    @Published public var availableProjects: [String] = []
    @Published public var selectedProject: String? = nil {
        didSet {
            guard oldValue != selectedProject else { return }
            Task { await reloadSessions() }
        }
    }
    @Published public var isGroupedByProject: Bool = false
    @Published public var collapsedProjects: Set<String> = []

    @Published public var isLoading: Bool = false
    @Published public var isLoadingNextPage: Bool = false
    @Published public var isLoadingDetail: Bool = false
    @Published public var isLoadingMoreEvents: Bool = false
    @Published public var isDeletingSession: Bool = false
    @Published public var errorMessage: String? = nil

    private let facade: UsageQueryFacade
    private var searchCancellable: Task<Void, Never>?
    private var nextCursor: String?
    private var queryGeneration = 0
    private let pageSize = 50
    private let eventPageSize = 500

    public var hasMoreSessions: Bool { nextCursor != nil }

    public init(facade: UsageQueryFacade) {
        self.facade = facade
    }

    public var groupedSessions: [ProjectSessionGroup] {
        var order: [String] = []
        var map: [String: [CodexSessionDTO]] = [:]

        for session in sessions {
            let proj = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = proj.isEmpty ? "__unnamed__" : proj
            if map[key] == nil {
                order.append(key)
                map[key] = []
            }
            map[key]?.append(session)
        }

        return order.compactMap { key -> ProjectSessionGroup? in
            guard let list = map[key], !list.isEmpty else { return nil }
            let isUnnamed = key == "__unnamed__"
            let displayName = isUnnamed ? L10n.text("默认未命名项目", "Default / Unnamed") : key
            let totalTokens = list.reduce(Int64(0)) { $0 + $1.tokens.canonicalTotalTokens }
            let totalCost = list.reduce(MoneyNanoUSD.zero) {
                $1.summaryProvenance == .legacyAggregate ? $0 : $0 + $1.estimatedCost
            }
            let legacyCost = list.reduce(MoneyNanoUSD.zero) {
                $1.summaryProvenance == .legacyAggregate ? $0 + $1.estimatedCost : $0
            }
            return ProjectSessionGroup(
                project: key,
                displayName: displayName,
                sessions: list,
                totalTokens: totalTokens,
                totalCost: totalCost,
                legacyAggregateCost: legacyCost,
                sessionCount: list.count
            )
        }
    }

    public func isProjectCollapsed(_ project: String) -> Bool {
        collapsedProjects.contains(project)
    }

    public func toggleProjectCollapse(_ project: String) {
        if collapsedProjects.contains(project) {
            collapsedProjects.remove(project)
        } else {
            collapsedProjects.insert(project)
        }
    }

    public func expandAllProjects() {
        collapsedProjects.removeAll()
    }

    public func collapseAllProjects() {
        let allKeys = groupedSessions.map(\.project)
        collapsedProjects = Set(allKeys)
    }

    public func clearProjectFilter() {
        selectedProject = nil
    }

    public func reloadSessions() async {
        queryGeneration += 1
        let generation = queryGeneration
        isLoading = true
        isLoadingNextPage = false
        nextCursor = nil
        errorMessage = nil
        do {
            if let projects = try? await facade.getProjectNames() {
                self.availableProjects = projects
            }

            let page = try await facade.getSessionPage(
                sort: sortOption,
                search: searchText.isEmpty ? nil : searchText,
                project: selectedProject,
                limit: pageSize
            )
            guard generation == queryGeneration else { return }
            self.sessions = page.sessions
            self.nextCursor = page.nextCursor
            if selectedSessionId == nil, let first = page.sessions.first {
                self.selectedSessionId = first.sessionId
            }
        } catch {
            guard generation == queryGeneration else { return }
            self.errorMessage = Self.userFacingError(error)
        }
        if generation == queryGeneration {
            isLoading = false
        }
    }

    public func loadNextPage() async {
        guard !isLoading, !isLoadingNextPage, let cursor = nextCursor else { return }
        let generation = queryGeneration
        isLoadingNextPage = true
        defer {
            if generation == queryGeneration { isLoadingNextPage = false }
        }
        do {
            let page = try await facade.getSessionPage(
                sort: sortOption,
                search: searchText.isEmpty ? nil : searchText,
                project: selectedProject,
                limit: pageSize,
                cursor: cursor
            )
            guard generation == queryGeneration else { return }
            let existingIDs = Set(sessions.map(\.sessionId))
            sessions.append(contentsOf: page.sessions.filter { !existingIDs.contains($0.sessionId) })
            nextCursor = page.nextCursor
        } catch {
            guard generation == queryGeneration else { return }
            errorMessage = Self.userFacingError(error)
        }
    }

    public func loadSelectedSessionDetail() async {
        guard let sid = selectedSessionId else {
            selectedDetail = nil
            return
        }
        isLoadingDetail = true
        do {
            self.selectedDetail = try await facade.getSessionDetail(
                sessionId: sid,
                eventLimit: eventPageSize
            )
        } catch {
            self.errorMessage = Self.userFacingError(error)
        }
        isLoadingDetail = false
    }

    public func loadMoreSelectedSessionEvents() async {
        guard !isLoadingDetail,
              !isLoadingMoreEvents,
              let current = selectedDetail,
              current.hasMoreEvents,
              let cursor = current.nextEventCursor else { return }
        let sessionId = current.session.sessionId
        isLoadingMoreEvents = true
        defer { isLoadingMoreEvents = false }
        do {
            guard let page = try await facade.getSessionDetail(
                sessionId: sessionId,
                eventLimit: eventPageSize,
                eventCursor: cursor
            ) else { return }
            guard selectedSessionId == sessionId, let existing = selectedDetail else { return }
            let seen = Set(existing.recentEvents.map(\.eventId))
            let mergedEvents = existing.recentEvents + page.recentEvents.filter { !seen.contains($0.eventId) }
            selectedDetail = CodexSessionDetailDTO(
                session: page.session,
                subagents: page.subagents,
                modelSummaries: page.modelSummaries,
                recentEvents: mergedEvents,
                totalEventCount: page.totalEventCount,
                loadedEventCount: mergedEvents.count,
                hasMoreEvents: page.hasMoreEvents,
                nextEventCursor: page.nextEventCursor,
                sourcePath: page.sourcePath,
                relativePath: page.relativePath,
                totalSubagentTokens: page.totalSubagentTokens,
                totalSubagentCost: page.totalSubagentCost
            )
        } catch {
            errorMessage = Self.userFacingError(error)
        }
    }

    @discardableResult
    public func deleteSession(_ session: CodexSessionDTO) async -> Bool {
        guard !isDeletingSession else { return false }
        isDeletingSession = true
        errorMessage = nil
        defer { isDeletingSession = false }

        do {
            try await facade.deleteSession(sessionId: session.sessionId)
            if selectedSessionId == session.sessionId
                || selectedDetail?.session.rootSessionId == session.rootSessionId {
                selectedSessionId = nil
                selectedDetail = nil
            }
            await reloadSessions()
            return true
        } catch {
            errorMessage = Self.userFacingError(error)
            return false
        }
    }

    private static func userFacingError(_ error: Error) -> String {
        if let description = (error as? SessionDeletionError)?.errorDescription {
            return description
        }
        return L10n.text(
            "暂时无法读取本地用量记录，请稍后重试。",
            "Local usage records could not be loaded right now. Try again later."
        )
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
