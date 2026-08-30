// Codex CLI 二进制路径检索与版本探测

import Foundation
import Darwin

public struct CodexBinaryLookupResult: Sendable {
    public let binaryPath: String?
    public let failureReason: String?
    public let inspectedPaths: [String]

    public var isFound: Bool {
        binaryPath != nil
    }
}

public struct CodexBinaryLocator: Sendable {
    public static let standardSearchPaths: [String] = [
        "~/.codex/bin/codex",
        "~/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.bun/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.cargo/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "~/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "~/Applications/Codex.app/Contents/Resources/codex",
        "/usr/bin/codex",
        "/bin/codex"
    ]

    /// 探测可用的 codex 二进制路径
    public static func locateBinary(customPath: String? = nil) -> String? {
        inspectBinary(customPath: customPath).binaryPath
    }

    public static func inspectBinary(customPath: String? = nil) -> CodexBinaryLookupResult {
        let fileManager = FileManager.default
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        var inspectedPaths: [String] = []
        var customPathIssue: String?
        var shellPathIssue: String?

        func inspectPath(_ path: String) -> String? {
            let expanded = expandedPath(path, homePath: homePath)
            if !inspectedPaths.contains(expanded) {
                inspectedPaths.append(expanded)
            }
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        if let custom = customPath, !custom.isEmpty {
            let expanded = expandedPath(custom.trimmingCharacters(in: .whitespacesAndNewlines), homePath: homePath)
            if let binaryPath = inspectPath(expanded) {
                return CodexBinaryLookupResult(binaryPath: binaryPath, failureReason: nil, inspectedPaths: inspectedPaths)
            }

            customPathIssue = fileManager.fileExists(atPath: expanded)
                ? L10n.format("The selected Codex path exists but is not executable: %@", zhHans: "已选择的 Codex 路径存在，但不可执行：%@", expanded)
                : L10n.format("The selected Codex path does not exist: %@", zhHans: "已选择的 Codex 路径不存在：%@", expanded)
        }

        for candidate in standardSearchPaths {
            if let binaryPath = inspectPath(candidate) {
                return CodexBinaryLookupResult(binaryPath: binaryPath, failureReason: nil, inspectedPaths: inspectedPaths)
            }
        }

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            let components = envPath.split(separator: ":").map(String.init)
            for dir in components {
                let candidate = (dir as NSString).appendingPathComponent("codex")
                if let binaryPath = inspectPath(candidate) {
                    return CodexBinaryLookupResult(binaryPath: binaryPath, failureReason: nil, inspectedPaths: inspectedPaths)
                }
            }
        }

        let shellResult = locateViaLoginShell()
        if let loginShellCandidate = shellResult.path, !loginShellCandidate.isEmpty {
            if let binaryPath = inspectPath(loginShellCandidate) {
                return CodexBinaryLookupResult(binaryPath: binaryPath, failureReason: nil, inspectedPaths: inspectedPaths)
            }
            shellPathIssue = fileManager.fileExists(atPath: loginShellCandidate)
                ? L10n.format("The login shell returned a non-executable Codex path: %@", zhHans: "登录 Shell 返回了不可执行的 Codex 路径：%@", loginShellCandidate)
                : L10n.format("The login shell returned a missing Codex path: %@", zhHans: "登录 Shell 返回的 Codex 路径不存在：%@", loginShellCandidate)
        }

        let reason = failureReason(
            customPathIssue: customPathIssue,
            shellIssue: shellPathIssue ?? shellResult.errorMessage,
            hasLocalCredentials: hasLocalCredentials(homePath: homePath)
        )
        return CodexBinaryLookupResult(binaryPath: nil, failureReason: reason, inspectedPaths: inspectedPaths)
    }

    private struct LoginShellLookupResult: Sendable {
        let path: String?
        let errorMessage: String?
    }

    private static func locateViaLoginShell() -> LoginShellLookupResult {
        let result = runLoginShell(command: "command -v codex", timeout: 2)
        if let output = result.output, !output.isEmpty {
            return LoginShellLookupResult(path: output, errorMessage: nil)
        }
        return LoginShellLookupResult(
            path: nil,
            errorMessage: result.errorMessage ?? L10n.text(
                "登录 Shell 的 PATH 中没有 codex。",
                "codex was not found in the login shell PATH."
            )
        )
    }

    private static func runLoginShell(
        command: String,
        timeout: TimeInterval
    ) -> (output: String?, errorMessage: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", command]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                let stopDeadline = Date().addingTimeInterval(0.2)
                while process.isRunning && Date() < stopDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return (nil, L10n.text("登录 Shell 检查超时。", "Login shell inspection timed out."))
            }
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, let output, !output.isEmpty {
                return (output, nil)
            }

            let shellError = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = shellError?.isEmpty == false
                ? shellError
                : L10n.text("登录 Shell 的 PATH 中没有 codex。", "codex was not found in the login shell PATH.")
            return (nil, message)
        } catch {
            return (nil, L10n.format("Unable to inspect the login shell PATH: %@", zhHans: "无法检查登录 Shell 的 PATH：%@", error.localizedDescription))
        }
    }

    private static let cachedLoginShellPATH: String? = {
        runLoginShell(command: "printf %s \"$PATH\"", timeout: 2).output
    }()

    public static func augmentedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin"
        ]
        let shellParts = (cachedLoginShellPATH ?? "").split(separator: ":").map(String.init)
        let currentParts = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (extras + shellParts + currentParts)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private static func expandedPath(_ path: String, homePath: String) -> String {
        if path == "~" {
            return homePath
        }
        if path.hasPrefix("~/") {
            return homePath + String(path.dropFirst())
        }
        return path
    }

    private static func hasLocalCredentials(homePath: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(homePath)/.codex/auth.json")
    }

    private static func failureReason(customPathIssue: String?, shellIssue: String?, hasLocalCredentials: Bool) -> String {
        let base = hasLocalCredentials
            ? L10n.text(
                "已读取到本地登录凭据，但没有找到 Codex 可执行文件。这通常不是文件管理器权限问题；凭据在 ~/.codex/auth.json，CLI 可执行文件需要位于 ChatGPT.app、Homebrew、~/.codex/bin 或登录 Shell 的 PATH 中。",
                "Local sign-in credentials were found, but the Codex executable was not. This is usually not a file-manager permission issue; credentials live in ~/.codex/auth.json, while the CLI executable must be in ChatGPT.app, Homebrew, ~/.codex/bin, or the login shell PATH."
            )
            : L10n.text(
                "没有找到 Codex 可执行文件，也没有检测到本地登录凭据。请先安装并登录 Codex，或在设置中手动选择 codex 可执行文件。",
                "The Codex executable was not found, and local sign-in credentials were not detected. Install and sign in to Codex, or choose the codex executable manually in Settings."
            )

        return [customPathIssue, base, shellIssue].compactMap { issue in
            guard let issue, !issue.isEmpty else { return nil }
            return issue
        }.joined(separator: "\n")
    }

    /// 执行 --version 获取版本信息
    public static func queryVersion(at binaryPath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = ["--version"]
                process.environment = augmentedEnvironment()

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(2)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                    if process.isRunning {
                        process.terminate()
                        continuation.resume(returning: nil)
                        return
                    }
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
