// QuotaLens 本机线程用量与快照差分 Actor

import Foundation

public actor LocalUsageProbeActor {
    private let transport: JSONRPCTransport
    private let repositories: Repositories
    private let deviceId: String
    private var previousSnapshotsMap: [String: ThreadUsageSnapshotRecord] = [:]

    public init(transport: JSONRPCTransport, repositories: Repositories, deviceId: String = "macOS_local") {
        self.transport = transport
        self.repositories = repositories
        self.deviceId = deviceId
        self.previousSnapshotsMap = (try? repositories.getLatestThreadUsageSnapshots(deviceId: deviceId)) ?? [:]
    }

    public func reloadBaselineSnapshots() {
        previousSnapshotsMap = (try? repositories.getLatestThreadUsageSnapshots(deviceId: deviceId)) ?? [:]
    }

    /// 处理 thread/tokenUsage/updated 推送通知或主动轮询的快照
    public func ingestThreadUsage(
        threadId: String,
        modelRaw: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        totalTokens: Int64,
        estimatedCreditsMicros: Int64,
        activeMeterVersionId: String?,
        currentCycleId: String?
    ) {
        let now = Int64(Date().timeIntervalSince1970)
        let canonicalModel = ModelAliasResolver.resolve(rawModel: modelRaw)

        let snapshot = ThreadUsageSnapshotRecord(
            deviceId: deviceId,
            observedAt: now,
            threadId: threadId,
            modelRaw: modelRaw,
            modelCanonical: canonicalModel,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            estimatedCreditsMicros: estimatedCreditsMicros,
            rawJson: "{}"
        )

        let result = UsageSnapshotDiffer.diffSnapshots(
            currentSnapshots: [snapshot],
            previousSnapshotsMap: previousSnapshotsMap,
            activeMeterVersionId: activeMeterVersionId,
            currentCycleId: currentCycleId
        )

        // 更新基线表
        for snap in result.updatedSnapshots {
            previousSnapshotsMap[snap.threadId] = snap
            try? repositories.insertThreadUsageSnapshot(snap)
        }

        // 保存新生成的事件
        for ev in result.newEvents {
            try? repositories.insertUsageEvent(ev)
        }
    }
}
