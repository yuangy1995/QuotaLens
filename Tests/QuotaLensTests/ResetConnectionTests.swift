import XCTest
@testable import QuotaLens

final class ResetConnectionTests: XCTestCase {
    func testIndependentConnectionSurvivesMonitoringStop() async throws {
        let monitoring = JSONRPCTransport()
        let redemption = JSONRPCTransport()
        let monitoringInput = Pipe(), monitoringOutput = Pipe()
        let resetInput = Pipe(), resetOutput = Pipe()
        await monitoring.start(stdin: monitoringInput.fileHandleForReading, stdout: monitoringOutput.fileHandleForWriting)
        await redemption.start(stdin: resetInput.fileHandleForReading, stdout: resetOutput.fileHandleForWriting)
        let resetID = await redemption.connectionID()
        await monitoring.stop()
        // Closing the peer wakes the old blocking reader without touching the reset pipe.
        try monitoringInput.fileHandleForWriting.close()
        do {
            let peer = Task.detached {
                _ = resetOutput.fileHandleForReading.availableData
                try resetInput.fileHandleForWriting.write(contentsOf: Data(#"{"id":1,"result":{"outcome":"reset"}}"#.utf8) + Data([10]))
            }
            let response = try await redemption.sendRequest(
                method: ConsumeRateLimitResetCreditRequest.method,
                timeoutSeconds: 1, expectedConnectionID: resetID)
            XCTAssertNotNil(response.result)
            try await peer.value
            let currentID = await redemption.connectionID()
            XCTAssertEqual(currentID, resetID)
            await redemption.stop()
            try resetInput.fileHandleForWriting.close()
        } catch {
            await redemption.stop()
            try? resetInput.fileHandleForWriting.close()
            throw error
        }
    }

    func testLocalCodexHandshakeOnly() async throws {
        guard ProcessInfo.processInfo.environment["QUOTALENS_TEST_LOCAL_HANDSHAKE"] == "1" else { throw XCTSkip("Opt-in local handshake only") }
        let transport = JSONRPCTransport()
        let manager = CodexProcessManager(transport: transport, maximumReconnectAttempts: 0)
        let started = await manager.start()
        let status = await manager.getStatus()
        await manager.stop()
        XCTAssertTrue(started, "\(status)")
    }

    func testCodexNotificationWithoutVersionHeader() throws {
        let data = Data(#"{"emittedAtMs":1,"method":"remoteControl/status/changed","params":{"status":"disabled"}}"#.utf8)
        let message = try JSONDecoder().decode(JSONRPCNotification.self, from: data)
        XCTAssertEqual(message.method, "remoteControl/status/changed")
        XCTAssertEqual(message.jsonrpc, "2.0")
    }
}
