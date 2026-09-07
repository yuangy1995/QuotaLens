import Foundation

enum ResetCreditUseError: String, LocalizedError {
    case unavailable, accountChanged, unsupported, incompatible, uncertain, busy, disconnected

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L10n.text("无法确认这张重置卡仍然可用，请刷新后重试。", "This reset card could not be verified as available. Refresh and try again.")
        case .accountChanged:
            return L10n.text("登录账号与这张重置卡不一致，请刷新并确认账号后重试。", "The signed-in account does not match this reset card. Refresh and check your account before trying again.")
        case .unsupported:
            return L10n.text("当前连接的 Codex 不支持使用重置卡，请更新 Codex 或 ChatGPT 后重试。", "The connected Codex does not support using reset cards. Update Codex or ChatGPT and try again.")
        case .incompatible:
            return L10n.text("当前版本无法完成这次重置，请更新 Codex 或 ChatGPT 后重试。", "This version could not complete the reset. Update Codex or ChatGPT and try again.")
        case .uncertain:
            return L10n.text("暂时无法确认重置结果。请先刷新额度；如需重试，请仍使用同一张卡，不要改用其他卡。", "The reset result could not be confirmed. Refresh your quota first; if you retry, use the same card, not another one.")
        case .busy:
            return L10n.text("正在处理一次重置，请等待完成。", "A reset is already in progress. Please wait.")
        case .disconnected:
            return L10n.text("无法连接 Codex，请恢复连接后重试。", "Could not connect to Codex. Reconnect and try again.")
        }
    }
}

/// Only this flow can submit a reset. Reads and redemption use the same pinned connection.
@MainActor
enum ResetCreditRedemption {
    static func consume(
        credit: ResetCreditDisplay,
        accountKey: String,
        accountEmailHash: String?,
        idempotencyKey: String,
        isRetry: Bool = false,
        isCurrentAccount: () -> Bool,
        willSubmit: () throws -> Void = {},
        send: (String, [String: AnyCodable]) async throws -> JSONRPCResponse
    ) async throws -> ConsumeRateLimitResetCreditOutcome {
        var submitted = false
        func request<T: Decodable>(_ method: String, params: [String: AnyCodable] = [:], as: T.Type) async throws -> T {
            let response: JSONRPCResponse
            do {
                response = try await send(method, params)
            } catch {
                let rpcError = error as NSError
                if rpcError.domain == "JSONRPCTransport" {
                    if rpcError.code == -32601 { throw ResetCreditUseError.unsupported }
                    if rpcError.code == -32602 { throw ResetCreditUseError.incompatible }
                }
                throw error
            }
            if let error = response.error {
                if error.code == -32601 { throw ResetCreditUseError.unsupported }
                if error.code == -32602 { throw ResetCreditUseError.incompatible }
                throw RPCPayloadError.invalidPayload(method: method)
            }
            guard let result = response.result else { throw RPCPayloadError.missingResult(method: method) }
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result))
        }

        do {
            guard credit.accountKey == accountKey, isCurrentAccount() else { throw ResetCreditUseError.accountChanged }
            let account = try await request("account/read", as: AccountReadResult.self).account
            guard let account, account.type?.lowercased() == "chatgpt" else { throw ResetCreditUseError.accountChanged }
            if let identifier = account.accountId ?? account.id {
                guard AccountIdentity.stableAccountKey(from: identifier) == accountKey else { throw ResetCreditUseError.accountChanged }
            } else {
                guard let email = account.email, !email.isEmpty,
                      AccountIdentity.emailHash(from: email) == accountEmailHash else { throw ResetCreditUseError.accountChanged }
            }
            let before = try await request("account/rateLimits/read", as: RateLimitsReadResult.self)
            // Never redeem an ID fabricated for display or restored only from stale cache.
            guard !credit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !credit.id.hasPrefix("reset_credit_") else { throw ResetCreditUseError.unavailable }
            let live = before.rateLimitResetCredits?.credits?.first(where: { $0.id == credit.id })
            // A timed-out successful attempt may already have removed the card.
            // Replaying its persisted key is the only safe way to retrieve that result.
            guard isRetry || (live.map { live in
                  live.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "available"
                  && (live.expiresAt.map({ $0 > Int64(Date().timeIntervalSince1970) }) ?? true)
            } ?? false) else {
                throw ResetCreditUseError.unavailable
            }
            guard isCurrentAccount() else { throw ResetCreditUseError.accountChanged }
            try willSubmit()
            let params = ConsumeRateLimitResetCreditRequest(creditId: credit.id, idempotencyKey: idempotencyKey).params
            submitted = true
            let result = try await request(ConsumeRateLimitResetCreditRequest.method, params: params, as: ConsumeRateLimitResetCreditResponse.self)
            return result.outcome
        } catch {
            if let known = error as? ResetCreditUseError { throw known }
            throw submitted ? ResetCreditUseError.uncertain : ResetCreditUseError.disconnected
        }
    }
}
