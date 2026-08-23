// Codex App Server JSON-RPC 2.0 传输解析与响应分发

import Foundation

public actor JSONRPCTransport {
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var nextRequestId: Int64 = 1
    private var pendingRequests: [Int64: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var notificationHandlers: [(JSONRPCNotification) -> Void] = []
    private var isRunning: Bool = false
    private var lineBuffer = Data()

    public init() {}

    /// 注册通知监听回调
    public func onNotification(_ handler: @escaping @Sendable (JSONRPCNotification) -> Void) {
        notificationHandlers.append(handler)
    }

    /// 启动管道监听
    public func start(stdin: FileHandle, stdout: FileHandle) {
        self.inputHandle = stdin
        self.outputHandle = stdout
        self.isRunning = true
        self.nextRequestId = 1
        self.pendingRequests.removeAll()

        // 启动后台异步读取循环
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.readLoop()
        }
    }

    /// 停止通信
    public func stop() {
        isRunning = false
        inputHandle = nil
        outputHandle = nil

        let error = NSError(domain: "JSONRPCTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.text("通信传输已断开", "Transport disconnected")])
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    /// 发送 JSON-RPC 请求并等待响应 (支持超时)
    public func sendRequest(method: String, params: [String: AnyCodable]? = nil, timeoutSeconds: Double = 5.0) async throws -> JSONRPCResponse {
        guard isRunning, let output = outputHandle else {
            throw NSError(domain: "JSONRPCTransport", code: -100, userInfo: [NSLocalizedDescriptionKey: L10n.text("App Server 未启动或已断开", "App Server is not running or has disconnected")])
        }

        let requestId = nextRequestId
        nextRequestId += 1

        let request = JSONRPCRequest(id: requestId, method: method, params: params)
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)

        var payload = data
        payload.append(0x0A) // 换行符 \n

        // 等待响应与超时处理
        return try await withCheckedThrowingContinuation { continuation in
            registerPendingRequest(id: requestId, continuation: continuation)

            do {
                try output.write(contentsOf: payload)
            } catch {
                failPendingRequest(id: requestId, error: error)
                return
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.timeoutPendingRequest(id: requestId, method: method)
            }
        }
    }

    private func timeoutPendingRequest(id: Int64, method: String) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            let message = L10n.format("RPC request timed out: %@", zhHans: "RPC 请求超时: %@", method)
            let error = NSError(domain: "JSONRPCTransport", code: -101, userInfo: [NSLocalizedDescriptionKey: message])
            continuation.resume(throwing: error)
        }
    }

    private func registerPendingRequest(id: Int64, continuation: CheckedContinuation<JSONRPCResponse, Error>) {
        pendingRequests[id] = continuation
    }

    private func failPendingRequest(id: Int64, error: Error) {
        if let cont = pendingRequests.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func readLoop() async {
        guard let input = inputHandle else { return }

        while isRunning {
            do {
                let chunk = try input.read(upToCount: 4096)
                guard let chunk = chunk, !chunk.isEmpty else {
                    // EOF
                    break
                }
                self.processIncomingData(chunk)
            } catch {
                break
            }
        }
        self.stop()
    }

    private func processIncomingData(_ data: Data) {
        lineBuffer.append(data)

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)

            guard !lineData.isEmpty else { continue }

            do {
                let decoder = JSONDecoder()
                if let response = try? decoder.decode(JSONRPCResponse.self, from: lineData), let id = response.id {
                    if let error = response.error {
                        failPendingRequest(id: id, error: NSError(
                            domain: "JSONRPCTransport",
                            code: error.code,
                            userInfo: [NSLocalizedDescriptionKey: error.message]
                        ))
                    } else if let cont = pendingRequests.removeValue(forKey: id) {
                        cont.resume(returning: response)
                    }
                } else if let notif = try? decoder.decode(JSONRPCNotification.self, from: lineData) {
                    for handler in notificationHandlers {
                        handler(notif)
                    }
                }
            }
        }
    }
}
