import XCTest
@testable import QuotaLens

final class ResetConnectionTests: XCTestCase {
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
