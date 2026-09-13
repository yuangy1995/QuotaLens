import Foundation

struct QueryCredentialImportItem: Sendable {
    let credential: QueryCredential
    let name: String?
    let expectedAccountKey: String?
}

enum QueryCredentialTransfer {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumAccounts = 200

    static func parse(_ data: Data, provider: UsageProvider) throws -> [Result<QueryCredentialImportItem, QueryAccountError>] {
        guard data.count <= maximumBytes else { throw QueryAccountError.tooLarge }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw QueryAccountError.format }
        if !text.hasPrefix("{"), !text.hasPrefix("["), !text.hasPrefix("\"") {
            guard text.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw QueryAccountError.format }
            let refreshOnly = provider == .antigravity && text.hasPrefix("1//")
            let value = QueryCredential(accessToken: refreshOnly ? "" : text, refreshToken: refreshOnly ? text : nil,
                                        expiresAt: nil, isGCPToS: false)
            return [.success(.init(credential: value, name: nil, expectedAccountKey: nil))]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { throw QueryAccountError.format }
        if let token = object as? String { return try parse(Data(token.utf8), provider: provider) }
        var containerProvider: String?
        let entries: [Any]
        if let array = object as? [Any] { entries = array }
        else if let root = object as? [String: Any] {
            containerProvider = root["provider"] as? String
            if let array = root["accounts"] as? [Any] { entries = array }
            else { entries = [root] }
        } else { throw QueryAccountError.format }
        guard !entries.isEmpty, entries.count <= maximumAccounts else { throw QueryAccountError.tooLarge }
        return entries.map { entry in
            do {
                guard let row = entry as? [String: Any] else { throw QueryAccountError.format }
                if let declared = row["provider"] as? String ?? containerProvider,
                   declared.lowercased() != provider.rawValue { throw QueryAccountError.wrongProvider }
                if let mode = row["auth_mode"] as? String,
                   ["api_key", "desktop_gateway", "desktop_oauth"].contains(mode.lowercased()) { throw QueryAccountError.unsupported }
                var values = row
                for _ in 0..<4 {
                    if let nested = ["credential", "tokens", "token", "claude_credentials_raw", "credentials", "claudeAiOauth"]
                        .compactMap({ values[$0] as? [String: Any] }).first {
                        values = nested
                    } else { break }
                }
                func string(_ keys: [String]) -> String? {
                    keys.compactMap { values[$0] as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                }
                let access = string(["access_token", "accessToken"]) ?? ""
                let refresh = string(["refresh_token", "refreshToken"])
                guard !access.isEmpty || refresh != nil else { throw QueryAccountError.format }
                guard (access + (refresh ?? "")).unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw QueryAccountError.format }
                let expiryValue = values["expiry_timestamp"] ?? values["expires_at"] ?? values["expiresAt"]
                var expiry: Date?
                if let number = (expiryValue as? NSNumber)?.doubleValue ?? (expiryValue as? String).flatMap(Double.init) {
                    guard number.isFinite, number >= 0 else { throw QueryAccountError.format }
                    expiry = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
                } else if let raw = expiryValue as? String {
                    expiry = ISO8601DateFormatter().date(from: raw)
                    guard expiry != nil else { throw QueryAccountError.format }
                }
                let clientKey = string(["oauth_client_key"])
                if provider == .antigravity, let clientKey, clientKey != "antigravity_enterprise" { throw QueryAccountError.unsupported }
                let credential = QueryCredential(accessToken: access, refreshToken: refresh, expiresAt: expiry,
                    isGCPToS: (values["is_gcp_tos"] ?? values["isGCPToS"] ?? row["isGCPToS"]) as? Bool ?? false,
                    idToken: string(["id_token", "idToken"]), oauthClientKey: clientKey)
                return .success(.init(credential: credential, name: (row["name"] ?? row["account_name"]) as? String,
                                      expectedAccountKey: row["account_key"] as? String))
            } catch let error as QueryAccountError { return .failure(error) }
            catch { return .failure(.format) }
        }
    }

    static func export(provider: UsageProvider, entries: [(String, String, QueryCredential)]) throws -> Data {
        let rows: [[String: Any]] = entries.map { key, name, value in
            var credential: [String: Any] = ["access_token": value.accessToken, "is_gcp_tos": value.isGCPToS]
            if let refresh = value.refreshToken { credential["refresh_token"] = refresh }
            if let expiry = value.effectiveExpiry { credential["expires_at"] = expiry.timeIntervalSince1970 }
            if let id = value.idToken { credential["id_token"] = id }
            if let client = value.oauthClientKey { credential["oauth_client_key"] = client }
            return ["account_key": key, "name": name, "credential": credential]
        }
        return try JSONSerialization.data(withJSONObject: [
            "format": "quotalens-query-accounts", "version": 1, "provider": provider.rawValue, "accounts": rows
        ], options: [.prettyPrinted, .sortedKeys])
    }
}

extension QueryAccountError {
    var userMessage: String {
        switch self {
        case .credentialMissing: return L10n.text("凭据文件缺失，请重新导入或授权。", "Credential file is missing. Import or authorize again.")
        case .expired: return L10n.text("访问令牌已到期，需要续期或重新授权。", "Access token expired. Renew it or authorize again.")
        case .authorization: return L10n.text("授权被服务端拒绝，请重新授权。", "Authorization was rejected by the server. Authorize again.")
        case .format: return L10n.text("不支持此凭据格式，请导入账号 JSON 或有效 Token。", "Unsupported credential format. Import account JSON or a valid token.")
        case .identity: return L10n.text("账号身份不匹配，未保存此凭据。", "Account identity does not match. This credential was not saved.")
        case .wrongProvider: return L10n.text("文件中的账号不属于当前工具。", "Accounts in this file belong to a different tool.")
        case .unsupported: return L10n.text("此授权类型或 OAuth 客户端暂不支持额度查询。", "This authorization type or OAuth client is not supported for quota queries.")
        case .tooLarge: return L10n.text("文件为空或超过导入限制（8 MB、200 个账号）。", "File is empty or exceeds import limits (8 MB, 200 accounts).")
        case .storage: return L10n.text("本地加密凭据无法读取或保存，请检查存储权限。", "Local encrypted credentials could not be read or saved. Check storage permissions.")
        case .busy: return L10n.text("正在处理账号，请稍后重试。", "An account operation is in progress. Try again shortly.")
        case .unavailable: return L10n.text("查询暂时失败，请检查网络或稍后重试。", "Query temporarily failed. Check the network or try again later.")
        }
    }
}
