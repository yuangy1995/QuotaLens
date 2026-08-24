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

    public init() {}

    public func configure(database: SQLiteDatabase) {
        self.importActor = CodexUsageImportActor(database: database)
    }

    /// 触发扫描并导入（带 1 秒 Debounce，防止快速重复调用）
    public func triggerScan(forceRebuild: Bool = false) {
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
        lastGenerationPublishTime = .distantPast
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
                    guard let self = self else { return }
                    self.progress = currentProgress
                    self.statusText = status
                    self.publishDataGenerationIfNeeded(progress: currentProgress)
                }
            }

            self.lastScanSummary = summary
            self.lastScanTime = Date()
            self.dataGeneration &+= 1
            self.statusText = L10n.format("Scan complete, indexed %d files, added %d records", zhHans: "扫描完成，已索引 %d 个文件，新增 %d 条记录", summary.sourcesScanned, summary.eventsInserted)
        } catch {
            self.lastError = error.localizedDescription
            self.statusText = L10n.format("Scan failed: %@", zhHans: "扫描失败: %@", error.localizedDescription)
        }
    }

    private func publishDataGenerationIfNeeded(progress: Double) {
        let now = Date()
        guard progress >= 1.0 || now.timeIntervalSince(lastGenerationPublishTime) >= 2.5 else { return }
        dataGeneration &+= 1
        lastGenerationPublishTime = now
    }
}
