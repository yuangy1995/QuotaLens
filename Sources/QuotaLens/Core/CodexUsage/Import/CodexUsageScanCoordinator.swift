// QuotaLens 用量扫描协调器 (UI 响应式状态与后台刷新合并)

import Foundation
import SwiftUI
import Combine

@MainActor
public final class CodexUsageScanCoordinator: ObservableObject {
    public static let shared = CodexUsageScanCoordinator()

    @Published public private(set) var isScanning = false
    @Published public private(set) var progress: Double? = nil
    @Published public private(set) var statusText: String = ""
    @Published public private(set) var lastScanTime: Date? = nil
    @Published public private(set) var lastScanSummary: ImportSummary? = nil
    @Published public private(set) var dataGeneration: Int = 0
    @Published public private(set) var lastError: String? = nil

    private var importActor: CodexUsageImportActor?
    private var scanDebounceTask: Task<Void, Never>?
    private var lastRequestedScanTime: Date?
    private var lastGenerationPublishTime = Date.distantPast
    private var lastProgressPublishTime = Date.distantPast
    private let automaticRescanInterval: TimeInterval = 60
    private let progressPublishInterval: TimeInterval = 0.2
    private let generationPublishInterval: TimeInterval = 10

    public init() {}

    public func configure(database: SQLiteDatabase) {
        self.importActor = CodexUsageImportActor(database: database)
    }

    /// 触发扫描并导入（带 1 秒 Debounce，防止快速重复调用）
    public func triggerScan(forceRebuild: Bool = false) {
        let now = Date()
        if !forceRebuild {
            guard !isScanning else { return }
            if let lastScanTime,
               now.timeIntervalSince(lastScanTime) < automaticRescanInterval {
                return
            }
            if let lastRequestedScanTime,
               now.timeIntervalSince(lastRequestedScanTime) < 1 {
                return
            }
        }
        lastRequestedScanTime = now
        scanDebounceTask?.cancel()
        scanDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            await performScan(forceRebuild: forceRebuild)
        }
    }

    /// 立即强制执行扫描
    public func scanNow(forceRebuild: Bool = false) async {
        scanDebounceTask?.cancel()
        await performScan(forceRebuild: forceRebuild)
    }

    private func performScan(forceRebuild: Bool) async {
        guard let actor = importActor, !isScanning else { return }
        guard UsageFeatureFlags.shared.isAnalyticsEnabled else {
            progress = nil
            statusText = L10n.text("本地用量分析已停用", "Local analytics disabled")
            return
        }
        isScanning = true
        progress = 0.0
        statusText = L10n.text("准备扫描…", "Preparing scan...")
        lastError = nil
        lastGenerationPublishTime = Date()
        lastProgressPublishTime = .distantPast
        defer {
            isScanning = false
            progress = nil
        }

        let paths = CodexHistoryRootResolver.resolvePaths()

        do {
            let summary = try await actor.importCodexHistory(
                paths: paths,
                forceRebuild: forceRebuild
            ) { [weak self] currentProgress, status in
                Task { @MainActor [weak self] in
                    self?.publishProgressIfNeeded(
                        progress: currentProgress,
                        status: status
                    )
                }
            }

            self.lastScanSummary = summary
            self.lastScanTime = Date()
            self.dataGeneration &+= 1
            if let warning = summary.warningMessage {
                self.lastError = warning
                self.statusText = L10n.format("Usage update partially complete: %@", zhHans: "本地用量更新部分完成：%@", warning)
            } else {
                self.statusText = L10n.format("Usage update complete, read %d files, added %d records", zhHans: "本地用量更新完成，已读取 %d 个文件，新增 %d 条记录", summary.sourcesScanned, summary.eventsInserted)
            }
        } catch {
            let message = Self.userFacingError(error)
            self.lastError = message
            self.statusText = L10n.format("Usage update failed: %@", zhHans: "本地用量更新失败：%@", message)
        }
    }

    private static func userFacingError(_ error: Error) -> String {
        if let description = (error as? SessionDeletionError)?.errorDescription {
            return description
        }
        return L10n.text(
            "本地用量更新未完成，请稍后重试。",
            "Local usage update did not finish. Try again later."
        )
    }

    private func publishProgressIfNeeded(progress: Double, status: String) {
        guard isScanning else { return }
        let now = Date()
        guard progress >= 1
                || now.timeIntervalSince(lastProgressPublishTime) >= progressPublishInterval else {
            return
        }
        self.progress = progress
        if statusText != status {
            statusText = status
        }
        lastProgressPublishTime = now
        publishDataGenerationIfNeeded(progress: progress, now: now)
    }

    private func publishDataGenerationIfNeeded(progress: Double, now: Date) {
        guard progress < 1,
              now.timeIntervalSince(lastGenerationPublishTime) >= generationPublishInterval else {
            return
        }
        dataGeneration &+= 1
        lastGenerationPublishTime = now
    }
}
