// Codex App Server JSON-RPC 2.0 传输解析与响应分发

import Foundation
import Darwin

public enum JSONRPCTransportError: LocalizedError, Sendable, Equatable {
    case disconnected
    case connectionClosed
    case timedOut(method: String)
    case frameTooLarge(maxBytes: Int)
    case invalidFrame

    public var errorDescription: String? {
        switch self {
        case .disconnected:
            return L10n.text("连接未启动或已断开", "Connection is not running or has disconnected")
        case .connectionClosed:
            return L10n.text("连接已断开", "Connection disconnected")
        case .timedOut(let method):
            return L10n.format("RPC request timed out: %@", zhHans: "RPC 请求超时：%@", method)
        case .frameTooLarge:
            return L10n.text("Codex 返回的数据过大，连接已停止。", "The Codex response was too large, so the connection was stopped.")
        case .invalidFrame:
            return L10n.text("Codex 返回了无法识别的数据。", "Codex returned data that could not be read.")
        }
    }
}

public actor JSONRPCTransport {
    private struct PendingRequest {
        let connectionID: UUID
        let continuation: CheckedContinuation<JSONRPCResponse, Error>
    }

    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var currentConnectionID: UUID?
    private var readTask: Task<Void, Never>?
    private var nextRequestId: Int64 = 1
    private var pendingRequests: [Int64: PendingRequest] = [:]
    private var notificationHandlers: [@Sendable (JSONRPCNotification) -> Void] = []
    private var lineBuffer = Data()
    private let maximumFrameBytes: Int

    public init(maximumFrameBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumFrameBytes = max(1_024, maximumFrameBytes)
    }

    /// 注册通知监听回调
    public func onNotification(_ handler: @escaping @Sendable (JSONRPCNotification) -> Void) {
        notificationHandlers.append(handler)
    }

    /// 启动一代全新的管道监听。旧连接的 EOF 不会影响新连接。
    public func start(stdin: FileHandle, stdout: FileHandle) {
        stopCurrentConnection(error: JSONRPCTransportError.connectionClosed)

        let connectionID = UUID()
        inputHandle = stdin
        outputHandle = stdout
        currentConnectionID = connectionID
        nextRequestId = 1
        lineBuffer.removeAll(keepingCapacity: false)

        let inputDescriptor = stdin.fileDescriptor
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.readLoop(
                inputDescriptor: inputDescriptor,
                connectionID: connectionID
            )
        }
    }

    /// 停止通信，并恢复所有仍在等待响应的调用方。
    public func stop() {
        stopCurrentConnection(error: JSONRPCTransportError.connectionClosed)
    }

    /// 发送 JSON-RPC 请求并等待响应。
    public func sendRequest(
        method: String,
        params: [String: AnyCodable]? = nil,
        timeoutSeconds: Double = 5.0
    ) async throws -> JSONRPCResponse {
        guard let connectionID = currentConnectionID,
              let output = outputHandle else {
            throw JSONRPCTransportError.disconnected
        }

        let requestId = nextRequestId
        nextRequestId += 1

        var payload = try JSONEncoder().encode(
            JSONRPCRequest(id: requestId, method: method, params: params)
        )
        payload.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = PendingRequest(
                connectionID: connectionID,
                continuation: continuation
            )

            do {
                try output.write(contentsOf: payload)
            } catch {
                failPendingRequest(
                    id: requestId,
                    connectionID: connectionID,
                    error: error
                )
                stopOnlyIfCurrent(
                    connectionID,
                    error: JSONRPCTransportError.connectionClosed
                )
                return
            }

            Task { [weak self] in
                do {
                    let nanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                await self?.timeoutPendingRequest(
                    id: requestId,
                    method: method,
                    connectionID: connectionID
                )
            }
        }
    }

    /// 发送不带响应的 JSON-RPC 通知，并确认数据已写入当前连接。
    public func sendNotification(
        method: String,
        params: AnyCodable? = nil
    ) throws {
        guard let connectionID = currentConnectionID,
              let output = outputHandle else {
            throw JSONRPCTransportError.disconnected
        }

        var payload = try JSONEncoder().encode(
            JSONRPCNotification(method: method, params: params)
        )
        payload.append(0x0A)

        do {
            try output.write(contentsOf: payload)
        } catch {
            stopOnlyIfCurrent(
                connectionID,
                error: JSONRPCTransportError.connectionClosed
            )
            throw error
        }
    }

    private func timeoutPendingRequest(
        id: Int64,
        method: String,
        connectionID: UUID
    ) {
        guard let pending = pendingRequests[id],
              pending.connectionID == connectionID else {
            return
        }
        pendingRequests.removeValue(forKey: id)
        pending.continuation.resume(
            throwing: JSONRPCTransportError.timedOut(method: method)
        )
    }

    private func failPendingRequest(
        id: Int64,
        connectionID: UUID,
        error: Error
    ) {
        guard let pending = pendingRequests[id],
              pending.connectionID == connectionID else {
            return
        }
        pendingRequests.removeValue(forKey: id)
        pending.continuation.resume(throwing: error)
    }

    private nonisolated func readLoop(
        inputDescriptor: Int32,
        connectionID: UUID
    ) async {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while !Task.isCancelled,
              await isCurrentConnection(connectionID) {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(inputDescriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead < 0, errno == EINTR { continue }
            guard bytesRead > 0 else { break }
            let chunk = Data(buffer.prefix(bytesRead))
            await processIncomingData(chunk, connectionID: connectionID)
        }
        await stopOnlyIfCurrent(
            connectionID,
            error: JSONRPCTransportError.connectionClosed
        )
    }

    private func isCurrentConnection(_ connectionID: UUID) -> Bool {
        currentConnectionID == connectionID
    }

    private func processIncomingData(_ data: Data, connectionID: UUID) {
        guard currentConnectionID == connectionID else { return }
        lineBuffer.append(data)

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let frameLength = lineBuffer.distance(
                from: lineBuffer.startIndex,
                to: newlineIndex
            )
            guard frameLength <= maximumFrameBytes else {
                stopOnlyIfCurrent(
                    connectionID,
                    error: JSONRPCTransportError.frameTooLarge(maxBytes: maximumFrameBytes)
                )
                return
            }

            let lineData = lineBuffer.subdata(
                in: lineBuffer.startIndex..<newlineIndex
            )
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }

            let decoder = JSONDecoder()
            if let response = try? decoder.decode(JSONRPCResponse.self, from: lineData),
               let id = response.id {
                guard let pending = pendingRequests[id],
                      pending.connectionID == connectionID else {
                    continue
                }
                pendingRequests.removeValue(forKey: id)
                if let rpcError = response.error {
                    pending.continuation.resume(throwing: NSError(
                        domain: "JSONRPCTransport",
                        code: rpcError.code,
                        userInfo: [NSLocalizedDescriptionKey: rpcError.message]
                    ))
                } else {
                    pending.continuation.resume(returning: response)
                }
            } else if let notification = try? decoder.decode(
                JSONRPCNotification.self,
                from: lineData
            ) {
                for handler in notificationHandlers {
                    handler(notification)
                }
            } else {
                stopOnlyIfCurrent(
                    connectionID,
                    error: JSONRPCTransportError.invalidFrame
                )
                return
            }
        }

        if lineBuffer.count > maximumFrameBytes {
            stopOnlyIfCurrent(
                connectionID,
                error: JSONRPCTransportError.frameTooLarge(maxBytes: maximumFrameBytes)
            )
        }
    }

    private func stopOnlyIfCurrent(_ connectionID: UUID, error: Error) {
        guard currentConnectionID == connectionID else { return }
        stopCurrentConnection(error: error)
    }

    private func stopCurrentConnection(error: Error) {
        readTask?.cancel()
        readTask = nil

        let input = inputHandle
        let output = outputHandle
        inputHandle = nil
        outputHandle = nil
        currentConnectionID = nil
        lineBuffer.removeAll(keepingCapacity: false)

        for pending in pendingRequests.values {
            pending.continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()

        try? input?.close()
        try? output?.close()
    }
}
