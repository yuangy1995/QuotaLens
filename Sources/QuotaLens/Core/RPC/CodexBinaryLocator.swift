// Codex CLI 二进制路径检索与版本探测

import Foundation

public struct CodexBinaryLocator: Sendable {
    public static let standardSearchPaths: [String] = [
        "~/.codex/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.local/bin/codex",
        "~/.bun/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.cargo/bin/codex",
        "/usr/bin/codex",
        "/bin/codex"
    ]

    /// 探测可用的 codex 二进制路径
    public static func locateBinary(customPath: String? = nil) -> String? {
        let fileManager = FileManager.default
        let homePath = fileManager.homeDirectoryForCurrentUser.path

        // 1. 检查自定义路径
        if let custom = customPath, !custom.isEmpty {
            let expanded = custom.replacingOccurrences(of: "~", with: homePath)
            if fileManager.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        // 2. 检查标准预置绝对路径与用户目录路径
        let searchCandidates = [
            "\(homePath)/.codex/bin/codex",
            "\(homePath)/.local/bin/codex",
            "\(homePath)/.cargo/bin/codex",
            "\(homePath)/.bun/bin/codex",
            "\(homePath)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
            "/bin/codex"
        ]

        for candidate in searchCandidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 3. 检查系统 PATH 环境变量
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            let components = envPath.split(separator: ":").map(String.init)
            for dir in components {
                let candidate = (dir as NSString).appendingPathComponent("codex")
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        if let loginShellCandidate = locateViaLoginShell(), fileManager.isExecutableFile(atPath: loginShellCandidate) {
            return loginShellCandidate
        }

        return nil
    }

    private static func locateViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v codex"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    /// 执行 --version 获取版本信息
    public static func queryVersion(at binaryPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = ["--version"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
