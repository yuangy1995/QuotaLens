// QuotaLens 账户与额度探针 Actor
// 负责与真实 Codex App Server 交互并采集真实账户与额度数据

import Foundation

public actor AccountProbeActor {
    private let transport: JSONRPCTransport
    private let repositories: Repositories
    private var isPolling: Bool = false
    private var pollingTask: Task<Void, Never>?

    public init(transport: JSONRPCTransport, repositories: Repositories) {
        self.transport = transport
        self.repositories = repositories
    }

    /// 强制执行一次全量探针刷新
    public func probeAll() async {
        await probeAccount()
        await probeRateLimits()
    }

    /// 启动后台自动轮询
    public func startPolling(intervalSeconds: Double = 60.0) {
        stopPolling()
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.probeAll()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stopPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - 真实单项探针

    public func probeAccount() async {
        do {
            let response = try await transport.sendRequest(method: "account/read", params: [:])
            guard let result = response.result else {
                throw RPCPayloadError.missingResult(method: "account/read")
            }
            let data = try JSONEncoder().encode(result)
            let dto = try JSONDecoder().decode(AccountReadResult.self, from: data)
            guard dto.hasRecognizedPayload, let acc = dto.account else {
                throw RPCPayloadError.invalidPayload(method: "account/read")
            }
            let now = Int64(Date().timeIntervalSince1970)
            let identifier = acc.stableIdentifier
            let accountKey = AccountIdentity.stableAccountKey(from: identifier)
            let record = AccountRecord(
                accountKey: accountKey,
                emailHash: AccountIdentity.emailHash(from: identifier),
                planType: acc.planType ?? "pro",
                firstSeenAt: now,
                lastSeenAt: now
            )
            try? repositories.upsertAccount(record)
        } catch {
            // RPC 探针容错
        }
    }

    public func probeRateLimits() async {
        do {
            let response = try await transport.sendRequest(method: "account/rateLimits/read", params: [:])
            guard let result = response.result else {
                throw RPCPayloadError.missingResult(method: "account/rateLimits/read")
            }
            let data = try JSONEncoder().encode(result)
            let dto = try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
            guard dto.hasRecognizedPayload else {
                throw RPCPayloadError.invalidPayload(method: "account/rateLimits/read")
            }
            let now = Int64(Date().timeIntervalSince1970)
            let accountKey = (try? repositories.getLatestAccount()?.accountKey) ?? "acc_local"
            let rawJson = (try? JSONEncoder().encode(dto))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            if let defaultLimits = dto.rateLimits {
                try? insertSnapshots(
                    limits: defaultLimits,
                    fallbackLimitId: defaultLimits.limitId ?? "codex",
                    accountKey: accountKey,
                    observedAt: now,
                    rawJson: rawJson
                )
            }

            if let byLimit = dto.rateLimitsByLimitId {
                for (limitId, limits) in byLimit {
                    try? insertSnapshots(
                        limits: limits,
                        fallbackLimitId: limitId,
                        accountKey: accountKey,
                        observedAt: now,
                        rawJson: rawJson
                    )
                }
            }
        } catch {
            // 忽略单次失败
        }
    }

    private func insertSnapshots(
        limits: RateLimitsObject,
        fallbackLimitId: String,
        accountKey: String,
        observedAt: Int64,
        rawJson: String
    ) throws {
        let limitId = limits.limitId ?? fallbackLimitId
        if let primary = limits.primary {
            if let snapshot = snapshot(
                detail: primary,
                slot: "primary",
                accountKey: accountKey,
                observedAt: observedAt,
                limitId: limitId,
                planType: limits.planType,
                rawJson: rawJson
            ) {
                try repositories.insertRateLimitSnapshot(snapshot)
            }
        }
        if let secondary = limits.secondary {
            if let snapshot = snapshot(
                detail: secondary,
                slot: "secondary",
                accountKey: accountKey,
                observedAt: observedAt,
                limitId: limitId,
                planType: limits.planType,
                rawJson: rawJson
            ) {
                try repositories.insertRateLimitSnapshot(snapshot)
            }
        }
    }

    private func snapshot(
        detail: RateLimitWindowDetail,
        slot: String,
        accountKey: String,
        observedAt: Int64,
        limitId: String,
        planType: String?,
        rawJson: String
    ) -> RateLimitSnapshotRecord? {
        guard let usedPercentValue = detail.usedPercent else { return nil }
        let usedPercent = min(max(usedPercentValue, 0.0), 100.0)
        return RateLimitSnapshotRecord(
            accountKey: accountKey,
            observedAt: observedAt,
            limitId: limitId,
            slot: slot,
            usedPercentMilli: Int((usedPercent * 1000.0).rounded()),
            windowDurationMins: detail.windowDurationMins,
            resetsAt: detail.resetsAt,
            planType: planType,
            rawJson: rawJson
        )
    }

}
