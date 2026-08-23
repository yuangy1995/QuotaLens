// QuotaLens 本地 Codex 账号自动发现与导入模块
// 支持解析 ~/.codex/auth.json 与 config.toml 提取真实账号身份与套餐类型

import Foundation

public struct LocalAccountImporter: Sendable {
    public struct LocalIdentity: Sendable {
        public let accountKey: String
        public let displayName: String
        public let planType: String
    }

    /// 扫描本地 ~/.codex 目录并导入账号
    public static func importLocalAccounts(into repositories: Repositories) -> [AccountRecord] {
        var imported: [AccountRecord] = []
        let identities = discoverLocalIdentities()
        let now = Int64(Date().timeIntervalSince1970)

        for identity in identities {
            let account = AccountRecord(
                accountKey: identity.accountKey,
                emailHash: AccountIdentity.emailHash(from: identity.displayName),
                planType: identity.planType,
                firstSeenAt: now,
                lastSeenAt: now
            )

            try? repositories.upsertAccount(account)
            imported.append(account)
        }

        return imported
    }

    public static func displayNamesByAccountKey() -> [String: String] {
        var displayNames: [String: String] = [:]
        for identity in discoverLocalIdentities() {
            displayNames[identity.accountKey] = identity.displayName
        }
        return displayNames
    }

    public static func discoverLocalIdentities() -> [LocalIdentity] {
        var identities: [LocalIdentity] = []
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let codexDir = homeDir.appendingPathComponent(".codex", isDirectory: true)

        let authFile = codexDir.appendingPathComponent("auth.json")

        if fileManager.fileExists(atPath: authFile.path),
           let data = try? Data(contentsOf: authFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            var foundEmail: String? = nil
            var planType: String = "pro"

            // 尝试从 tokens.id_token (JWT) 解码 email 和 plan
            if let tokens = json["tokens"] as? [String: Any] {
                if let idToken = tokens["id_token"] as? String {
                    if let (email, plan) = decodeJWTPayload(idToken) {
                        foundEmail = email
                        if let p = plan { planType = p }
                    }
                }
                if let accountId = tokens["account_id"] as? String, foundEmail == nil {
                    foundEmail = "account_\(accountId.prefix(8))"
                }
            }

            // 如果有 OpenAI API KEY
            if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
                planType = "api"
            }

            let emailStr = foundEmail ?? "chatgpt_user"
            let accountKey = AccountIdentity.stableAccountKey(from: emailStr)

            identities.append(LocalIdentity(
                accountKey: accountKey,
                displayName: emailStr,
                planType: planType
            ))
        }

        return identities
    }

    /// 从 JWT 字符串安全解码 payload 中的 email 与 planType
    private static func decodeJWTPayload(_ jwt: String) -> (email: String?, plan: String?)? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padLength = (4 - (base64.count % 4)) % 4
        base64 += String(repeating: "=", count: padLength)

        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let email = (json["email"] as? String) ?? (json["sub"] as? String)

        var plan: String? = nil
        if let authDict = json["https://api.openai.com/auth"] as? [String: Any] {
            plan = authDict["chatgpt_plan_type"] as? String
        }

        return (email, plan)
    }
}
