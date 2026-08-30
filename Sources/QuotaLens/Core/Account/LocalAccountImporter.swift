// QuotaLens 本地 Codex 账号自动发现与导入模块

import Foundation

public struct LocalAccountImporter: Sendable {
    public struct LocalIdentity: Sendable {
        public let accountKey: String
        public let displayName: String
        public let planType: String
        public let emailHash: String
        public let legacyAccountKeys: [String]
    }

    /// 扫描本地 ~/.codex 目录并导入账号。
    public static func importLocalAccounts(into repositories: Repositories) -> [AccountRecord] {
        var imported: [AccountRecord] = []
        let identities = discoverLocalIdentities()
        let now = Int64(Date().timeIntervalSince1970)

        for identity in identities {
            for legacyKey in identity.legacyAccountKeys where legacyKey != identity.accountKey {
                try? repositories.migrateAccountKey(
                    from: legacyKey,
                    to: identity.accountKey
                )
            }

            let account = AccountRecord(
                accountKey: identity.accountKey,
                emailHash: identity.emailHash,
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
        let authFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        return discoverLocalIdentities(authFile: authFile)
    }

    static func discoverLocalIdentities(authFile: URL) -> [LocalIdentity] {
        guard FileManager.default.fileExists(atPath: authFile.path),
              let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let tokens = json["tokens"] as? [String: Any]
        let accountID = nonempty(tokens?["account_id"] as? String)
        let jwt = nonempty(tokens?["id_token"] as? String)
            .flatMap(decodeJWTPayload)
        let apiKey = nonempty(json["OPENAI_API_KEY"] as? String)

        let stableIdentifier = accountID
            ?? jwt?.subject
            ?? jwt?.email
            ?? apiKey.map { "api_key:\($0)" }
            ?? AccountIdentity.temporaryUnknownIdentifier()
        let accountKey = AccountIdentity.stableAccountKey(from: stableIdentifier)

        let displayName: String
        if let email = jwt?.email {
            displayName = email
        } else if let accountID {
            displayName = "account_\(accountID.prefix(8))"
        } else if apiKey != nil {
            displayName = L10n.text("OpenAI API 账号", "OpenAI API Account")
        } else {
            displayName = L10n.text("Codex 账号", "Codex Account")
        }

        var legacyIdentifiers: [String] = []
        if let email = jwt?.email {
            legacyIdentifiers.append(email)
        }
        if let subject = jwt?.subject {
            legacyIdentifiers.append(subject)
        }
        if let accountID {
            legacyIdentifiers.append("account_\(accountID.prefix(8))")
            legacyIdentifiers.append(accountID)
        }
        legacyIdentifiers.append("chatgpt_user")

        let legacyAccountKeys = Array(Set(
            legacyIdentifiers.map(AccountIdentity.stableAccountKey(from:))
        )).sorted()

        return [
            LocalIdentity(
                accountKey: accountKey,
                displayName: displayName,
                planType: apiKey == nil ? (jwt?.plan ?? "pro") : "api",
                emailHash: AccountIdentity.emailHash(
                    from: jwt?.email ?? stableIdentifier
                ),
                legacyAccountKeys: legacyAccountKeys
            )
        ]
    }

    /// JWT 仅用于本地显示与辅助匹配，不作为授权判断。
    private static func decodeJWTPayload(_ jwt: String) -> (
        email: String?,
        subject: String?,
        plan: String?
    )? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padLength = (4 - (base64.count % 4)) % 4
        base64 += String(repeating: "=", count: padLength)

        guard let data = Data(
            base64Encoded: base64,
            options: [.ignoreUnknownCharacters]
        ),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let email = nonempty(json["email"] as? String)
        let subject = nonempty(json["sub"] as? String)
        let plan = (json["https://api.openai.com/auth"] as? [String: Any])
            .flatMap { nonempty($0["chatgpt_plan_type"] as? String) }
        return (email, subject, plan)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
