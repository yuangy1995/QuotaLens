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
            detailLoadTask?.cancel()
            detailLoadTask = Task { @MainActor [weak self] in
                await self?.loadSelectedSessionDetail()
            }
        }
    }
    @Published public var selectedDetail: CodexSessionDetailDTO? = nil
    @Published public var selectedConversation: CodexSessionConversationDTO? = nil
    @Published public var searchText: String = "" {
        didSet {
            scheduleSessionsReload(afterNanoseconds: 250_000_000)
        }
    }
    @Published public var sortOption: SessionSort = .lastActivityDesc {
        didSet {
            scheduleSessionsReload()
        }
    }
    @Published public var availableProjects: [String] = []
    @Published public var selectedProject: String? = nil {
        didSet {
            guard oldValue != selectedProject else { return }
            scheduleSessionsReload()
        }
    }
    public let providerFilter: UsageProviderFilter
    @Published public var isGroupedByProject: Bool = false
    @Published public var collapsedProjects: Set<String> = []

    @Published public var isLoading: Bool = false
    @Published public var isLoadingNextPage: Bool = false
    @Published public var isLoadingDetail: Bool = false
    @Published public var isLoadingConversation: Bool = false
    @Published public var isLoadingMoreEvents: Bool = false
    @Published public var isDeletingSession: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var conversationErrorMessage: String? = nil

    private let facade: UsageQueryFacade
    private var sessionQueryTask: Task<Void, Never>?
    private var detailLoadTask: Task<Void, Never>?
    private var nextCursor: String?
    private var queryGeneration = 0
    private let pageSize = 50
    private let eventPageSize = 500

    public var hasMoreSessions: Bool { nextCursor != nil }

    public init(facade: UsageQueryFacade, providerFilter: UsageProviderFilter) {
        self.facade = facade
        self.providerFilter = providerFilter
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        isLoadingNextPage = false
        nextCursor = nil
        errorMessage = nil
        defer {
            if generation == queryGeneration {
                isLoading = false
            }
        }

        do {
            if let projects = try? await facade.getProjectNames(providerFilter: providerFilter) {
                self.availableProjects = projects
            }
            try Task.checkCancellation()

            let page = try await facade.getSessionPage(
                sort: sortOption,
                search: query.isEmpty ? nil : query,
                project: selectedProject,
                limit: pageSize,
                providerFilter: providerFilter
            )
            guard generation == queryGeneration else { return }
            self.sessions = page.sessions
            self.nextCursor = page.nextCursor

            if let selectedSessionId,
               page.sessions.contains(where: { $0.sessionId == selectedSessionId }) {
                return
            }
            self.selectedSessionId = page.sessions.first?.sessionId
        } catch is CancellationError {
            return
        } catch {
            guard generation == queryGeneration else { return }
            self.errorMessage = Self.userFacingError(error)
        }
    }

    public func loadNextPage() async {
        guard !isLoading, !isLoadingNextPage, let cursor = nextCursor else { return }
        let generation = queryGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoadingNextPage = true
        defer {
            if generation == queryGeneration { isLoadingNextPage = false }
        }
        do {
            let page = try await facade.getSessionPage(
                sort: sortOption,
                search: query.isEmpty ? nil : query,
                project: selectedProject,
                limit: pageSize,
                cursor: cursor,
                providerFilter: providerFilter
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
            selectedConversation = nil
            conversationErrorMessage = nil
            isLoadingDetail = false
            isLoadingConversation = false
            return
        }

        selectedDetail = nil
        selectedConversation = nil
        conversationErrorMessage = nil
        isLoadingDetail = true
        isLoadingConversation = false

        do {
            let detail = try await facade.getSessionDetail(
                sessionId: sid,
                eventLimit: eventPageSize
            )
            try Task.checkCancellation()
            guard selectedSessionId == sid else { return }
            self.selectedDetail = detail
        } catch is CancellationError {
            return
        } catch {
            guard selectedSessionId == sid else { return }
            self.errorMessage = Self.userFacingError(error)
            isLoadingDetail = false
            return
        }

        guard selectedSessionId == sid else { return }
        isLoadingDetail = false
        guard let selectedDetail else { return }

        guard selectedDetail.session.provider == .codex
            || selectedDetail.session.provider == .antigravity else {
            selectedConversation = CodexSessionConversationDTO(sessionId: sid, messages: [])
            isLoadingConversation = false
            return
        }

        isLoadingConversation = true
        do {
            let conversation = try await facade.getSessionConversation(sessionId: sid)
            try Task.checkCancellation()
            guard selectedSessionId == sid else { return }
            self.selectedConversation = conversation ?? CodexSessionConversationDTO(
                sessionId: sid,
                messages: []
            )
        } catch is CancellationError {
            return
        } catch {
            guard selectedSessionId == sid else { return }
            conversationErrorMessage = L10n.text(
                "暂时无法读取这条会话的对话内容。",
                "This conversation could not be read right now."
            )
        }
        if selectedSessionId == sid {
            isLoadingConversation = false
        }
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
        guard session.provider == .codex else { return false }
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
                selectedConversation = nil
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

    private func scheduleSessionsReload(afterNanoseconds delay: UInt64 = 0) {
        sessionQueryTask?.cancel()
        sessionQueryTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.reloadSessions()
        }
    }
}
