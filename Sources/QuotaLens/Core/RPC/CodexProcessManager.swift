// Codex App Server 子进程生命周期与连接管理器

import Foundation

public enum ProcessStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(version: String, binaryPath: String)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

public actor CodexProcessManager {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var transport: JSONRPCTransport
    private var status: ProcessStatus = .disconnected
    private var customBinaryPath: String?
    private var autoReconnect: Bool = true
    private var reconnectAttempts: Int = 0
    private var lastExitCode: Int32?

    public init(transport: JSONRPCTransport) {
        self.transport = transport
    }

    public func getStatus() -> ProcessStatus {
        return status
    }

    public func setCustomBinaryPath(_ path: String?) {
        self.customBinaryPath = path
    }

    /// 启动 codex app-server 子进程
    public func start() async -> Bool {
        let lookup = CodexBinaryLocator.inspectBinary(customPath: customBinaryPath)
        guard let binaryPath = lookup.binaryPath else {
            self.status = .failed(lookup.failureReason ?? L10n.text("未找到 Codex，请在设置中指定位置或安装 Codex。", "Codex was not found. Choose its location in Settings or install Codex."))
            return false
        }

        self.status = .connecting
        let version = await CodexBinaryLocator.queryVersion(at: binaryPath) ?? "codex (unknown)"

        stopProcessOnly()
        await transport.stop()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["app-server", "--stdio"]
        proc.environment = CodexBinaryLocator.augmentedEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            let pid = p.processIdentifier
            Task { [weak self] in
                await self?.handleProcessTermination(exitCode: p.terminationStatus, processIdentifier: pid)
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.stdinPipe = inPipe
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            self.reconnectAttempts = 0
            self.lastExitCode = nil
            self.status = .connected(version: version, binaryPath: binaryPath)

            await transport.start(stdin: outPipe.fileHandleForReading, stdout: inPipe.fileHandleForWriting)

            // 执行 LSP/JSON-RPC 标准初始化握手
            await self.performInitializeHandshake()

            return true
        } catch {
            self.status = .failed(L10n.format("Unable to start Codex: %@", zhHans: "无法启动 Codex：%@", error.localizedDescription))
            return false
        }
    }

    /// 执行 initialize 握手与 initialized 通知
    private func performInitializeHandshake() async {
        do {
            let initParams: [String: AnyCodable] = [
                "clientInfo": AnyCodable([
                    "name": "QuotaLens",
                    "version": AppVersion.marketingVersion
                ]),
                "capabilities": AnyCodable([:] as [String: Sendable])
            ]
            _ = try await transport.sendRequest(method: "initialize", params: initParams, timeoutSeconds: 3.0)

            // 发送 initialized 通知
            let notif = JSONRPCNotification(method: "initialized", params: AnyCodable([:] as [String: Sendable]))
            let encoder = JSONEncoder()
            if var payload = try? encoder.encode(notif), let inPipe = stdinPipe?.fileHandleForWriting {
                payload.append(0x0A)
                try? inPipe.write(contentsOf: payload)
            }
        } catch {
            // 握手容错
        }
    }

    /// 停止子进程
    public func stop() async {
        stopProcessOnly()
        await transport.stop()
        status = .disconnected
    }

    private func stopProcessOnly() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
    }

    private func handleProcessTermination(exitCode: Int32, processIdentifier: Int32) async {
        guard process?.processIdentifier == processIdentifier else {
            return
        }
        lastExitCode = exitCode
        status = .failed(L10n.format("Codex exited unexpectedly (code %d)", zhHans: "Codex 意外退出（代码 %d）", exitCode))
        await transport.stop()

        if autoReconnect && reconnectAttempts < 5 {
            reconnectAttempts += 1
            let jitter = Double.random(in: 0.2...0.8)
            let delaySeconds = min(30.0, pow(2.0, Double(reconnectAttempts))) + jitter
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            _ = await start()
        }
    }
}
