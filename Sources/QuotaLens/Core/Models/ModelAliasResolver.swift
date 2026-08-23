// QuotaLens 模型别名规范化解析器

import Foundation

public struct ModelAliasResolver: Sendable {
    public static let aliasVersionId = "model-alias-2026-07-v1"

    private static let staticAliases: [String: String] = [
        "sol": "gpt-5.6-sol",
        "gpt-5.6-sol": "gpt-5.6-sol",
        "terra": "gpt-5.6-terra",
        "gpt-5.6-terra": "gpt-5.6-terra",
        "luna": "gpt-5.6-luna",
        "gpt-5.6-luna": "gpt-5.6-luna",
        "gpt-5-sol": "gpt-5.6-sol",
        "gpt-5-terra": "gpt-5.6-terra",
        "gpt-5-luna": "gpt-5.6-luna"
    ]

    /// 将原始模型字符串规范化为标准模型标识
    public static func resolve(rawModel: String?) -> String {
        guard let raw = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return "unknown"
        }

        let normalized = raw
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if let canonical = staticAliases[normalized] ?? staticAliases[raw] {
            return canonical
        }

        for alias in ["gpt-5.6-sol", "gpt-5-sol", "gpt-5.6-terra", "gpt-5-terra", "gpt-5.6-luna", "gpt-5-luna"] {
            if normalized.contains(alias), let canonical = staticAliases[alias] {
                return canonical
            }
        }

        let tokens = normalized.split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init)
        for shortAlias in ["sol", "terra", "luna"] {
            if tokens.contains(shortAlias), let canonical = staticAliases[shortAlias] {
                return canonical
            }
        }

        return normalized
    }
}
