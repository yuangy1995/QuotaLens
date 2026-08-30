// Codex App Server 子进程生命周期与连接管理器

import Foundation

public enum ProcessStatus: Sendable, Equatable {
    case disconnected
    case launching
    case handshaking
    case connected(version: String, binaryPath: String)
    case reconnecting(attempt: Int)
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
    private let transport: JSONRPCTransport
    private var status: ProcessStatus = .disconnected
    private var statusHandlers: [@Sendable (ProcessStatus) -> Void] = []
    private var customBinaryPath: String?
    private var autoReconnect = true
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var stabilityTask: Task<Void, Never>?
    private var desiredRunning = false
    private var processGeneration: UInt64 = 0
    private var lastExitCode: Int32?
    private var stderrBuffer = Data()

    private let maximumReconnectAttempts: Int
    private let stableConnectionNanoseconds: UInt64
    private let reconnectDelayNanoseconds: @Sendable (Int) -> UInt64
    private static let maximumStderrBytes = 64 * 1_024

    public init(
        transport: JSONRPCTransport,
        maximumReconnectAttempts: Int = 5,
        stableConnectionSeconds: Double = 30,
        reconnectDelayNanoseconds: @escaping @Sendable (Int) -> UInt64 = { attempt in
            let jitter = Double.random(in: 0.2...0.8)
            let seconds = min(30.0, pow(2.0, Double(attempt))) + jitter
            return UInt64(seconds * 1_000_000_000)
        }
    ) {
        self.transport = transport
        self.maximumReconnectAttempts = max(0, maximumReconnectAttempts)
        self.stableConnectionNanoseconds = UInt64(
            max(0, stableConnectionSeconds) * 1_000_000_000
        )
        self.reconnectDelayNanoseconds = reconnectDelayNanoseconds
    }

    public func getStatus() -> ProcessStatus {
        status
    }

    public func onStatusChange(
        _ handler: @escaping @Sendable (ProcessStatus) -> Void
    ) {
        statusHandlers.append(handler)
        handler(status)
    }

    public func setCustomBinaryPath(_ path: String?) {
        customBinaryPath = path
    }

    /// 用户或上层恢复流程发起一次新的连接。
    public func start(resetReconnectAttempts: Bool = true) async -> Bool {
        if !resetReconnectAttempts {
            // 自动重连任务仍在等待时不重复启动；重试次数到达上限后，
            // 仍允许上层的低频恢复或定时刷新再尝试一次。
            guard reconnectTask == nil else {
                return false
            }
        }
        desiredRunning = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        if resetReconnectAttempts {
            reconnectAttempts = 0
        }
        processGeneration &+= 1
        return await launch(generation: processGeneration)
    }

    /// 完成首个有效业务 RPC 后，自动重连计数才可归零。
    public func markConnectionHealthy() {
        guard status.isConnected else { return }
        reconnectAttempts = 0
        stabilityTask?.cancel()
        stabilityTask = nil
    }

    public func reportTransportFailure(_ message: String) async {
        guard desiredRunning, status.isConnected else { return }
        let generation = processGeneration
        stabilityTask?.cancel()
        stabilityTask = nil
        stopProcessOnly()
        await transport.stop()
        updateStatus(.failed(message))
        scheduleReconnect(afterGeneration: generation)
    }

    public func recentStandardError() -> String {
        String(decoding: stderrBuffer, as: UTF8.self)
    }

    private func launch(generation: UInt64) async -> Bool {
        guard desiredRunning, generation == processGeneration else {
            return false
        }

        updateStatus(.launching)
        let lookup = CodexBinaryLocator.inspectBinary(customPath: customBinaryPath)
        guard let binaryPath = lookup.binaryPath else {
            updateStatus(.failed(
                lookup.failureReason
                    ?? L10n.text(
                        "未找到 Codex，请在设置中指定位置或安装 Codex。",
                        "Codex was not found. Choose its location in Settings or install Codex."
                    )
            ))
            return false
        }

        let version = await CodexBinaryLocator.queryVersion(at: binaryPath)
            ?? "codex (unknown)"
        guard desiredRunning, generation == processGeneration else {
            return false
        }

        stopProcessOnly()
        await transport.stop()
        guard desiredRunning, generation == processGeneration else {
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["app-server", "--stdio"]
        proc.environment = CodexBinaryLocator.augmentedEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.appendStandardError(data, generation: generation)
            }
        }

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] terminatedProcess in
            let pid = terminatedProcess.processIdentifier
            let exitCode = terminatedProcess.terminationStatus
            Task { [weak self] in
                await self?.handleProcessTermination(
                    exitCode: exitCode,
                    processIdentifier: pid,
                    generation: generation
                )
            }
        }

        do {
            try proc.run()
            guard desiredRunning, generation == processGeneration else {
                if proc.isRunning { proc.terminate() }
                return false
            }

            process = proc
            stdinPipe = inPipe
            stdoutPipe = outPipe
            stderrPipe = errPipe
            lastExitCode = nil
            stderrBuffer.removeAll(keepingCapacity: true)

            await transport.start(
                stdin: outPipe.fileHandleForReading,
                stdout: inPipe.fileHandleForWriting
            )
            try ensureCurrent(generation)
            updateStatus(.handshaking)
            try await performInitializeHandshake(generation: generation)
            try ensureCurrent(generation)

            updateStatus(.connected(version: version, binaryPath: binaryPath))
            scheduleStableConnectionReset(generation: generation)
            return true
        } catch is CancellationError {
            if generation == processGeneration {
                stopProcessOnly()
                await transport.stop()
                if !desiredRunning {
                    updateStatus(.disconnected)
                }
            }
            return false
        } catch {
            guard generation == processGeneration else { return false }
            stopProcessOnly()
            await transport.stop()
            guard desiredRunning else {
                updateStatus(.disconnected)
                return false
            }
            updateStatus(.failed(L10n.format(
                "Unable to connect to Codex: %@",
                zhHans: "无法连接 Codex：%@",
                error.localizedDescription
            )))
            scheduleReconnect(afterGeneration: generation)
            return false
        }
    }

    /// 执行 initialize 握手，并确认 initialized 通知成功写入同一代连接。
    private func performInitializeHandshake(generation: UInt64) async throws {
        let initParams: [String: AnyCodable] = [
            "clientInfo": AnyCodable([
                "name": "QuotaLens",
                "version": AppVersion.marketingVersion
            ]),
            "capabilities": AnyCodable([:] as [String: Sendable])
        ]
        let response = try await transport.sendRequest(
            method: "initialize",
            params: initParams,
            timeoutSeconds: 3.0
        )
        try ensureCurrent(generation)
        guard response.result != nil, response.error == nil else {
            throw NSError(
                domain: "QuotaLens.CodexHandshake",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.text(
                    "Codex 初始化响应无效。",
                    "The Codex initialization response was invalid."
                )]
            )
        }
        try await transport.sendNotification(
            method: "initialized",
            params: AnyCodable([:] as [String: Sendable])
        )
        try ensureCurrent(generation)
    }

    /// 停止子进程，并阻止任何已排队的重连再次启动它。
    public func stop() async {
        desiredRunning = false
        processGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        reconnectAttempts = 0
        stopProcessOnly()
        await transport.stop()
        updateStatus(.disconnected)
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard desiredRunning, generation == processGeneration else {
            throw CancellationError()
        }
    }

    private func stopProcessOnly() {
        let processToStop = process
        let input = stdinPipe
        let output = stdoutPipe
        let error = stderrPipe

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        error?.fileHandleForReading.readabilityHandler = nil

        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
        }
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        try? error?.fileHandleForReading.close()
    }

    private func handleProcessTermination(
        exitCode: Int32,
        processIdentifier: Int32,
        generation: UInt64
    ) async {
        guard generation == processGeneration,
              process?.processIdentifier == processIdentifier else {
            return
        }

        lastExitCode = exitCode
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        stabilityTask?.cancel()
        stabilityTask = nil
        await transport.stop()

        guard desiredRunning else {
            updateStatus(.disconnected)
            return
        }

        updateStatus(.failed(L10n.format(
            "Codex exited unexpectedly (code %d)",
            zhHans: "Codex 意外退出（代码 %d）",
            exitCode
        )))
        scheduleReconnect(afterGeneration: generation)
    }

    private func scheduleReconnect(afterGeneration generation: UInt64) {
        guard autoReconnect,
              desiredRunning,
              generation == processGeneration else {
            return
        }
        guard reconnectAttempts < maximumReconnectAttempts else {
            updateStatus(.failed(L10n.format(
                "Codex could not stay connected after %d attempts.",
                zhHans: "Codex 连续 %d 次无法保持连接。",
                maximumReconnectAttempts
            )))
            return
        }

        reconnectAttempts += 1
        let attempt = reconnectAttempts
        updateStatus(.reconnecting(attempt: attempt))
        reconnectTask?.cancel()
        let delay = reconnectDelayNanoseconds(attempt)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.runScheduledReconnect(
                expectedGeneration: generation
            )
        }
    }

    private func runScheduledReconnect(expectedGeneration: UInt64) async {
        reconnectTask = nil
        guard desiredRunning,
              expectedGeneration == processGeneration,
              !Task.isCancelled else {
            return
        }
        processGeneration &+= 1
        _ = await launch(generation: processGeneration)
    }

    private func scheduleStableConnectionReset(generation: UInt64) {
        stabilityTask?.cancel()
        let delay = stableConnectionNanoseconds
        stabilityTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            await self?.markStableConnection(generation: generation)
        }
    }

    private func markStableConnection(generation: UInt64) {
        guard generation == processGeneration,
              desiredRunning,
              status.isConnected else {
            return
        }
        reconnectAttempts = 0
        stabilityTask = nil
    }

    private func appendStandardError(_ data: Data, generation: UInt64) {
        guard generation == processGeneration else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > Self.maximumStderrBytes {
            stderrBuffer.removeFirst(stderrBuffer.count - Self.maximumStderrBytes)
        }
    }

    private func updateStatus(_ newStatus: ProcessStatus) {
        guard status != newStatus else { return }
        status = newStatus
        for handler in statusHandlers {
            handler(newStatus)
        }
    }
}
