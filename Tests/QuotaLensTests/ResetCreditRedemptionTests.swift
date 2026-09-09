import XCTest
@testable import QuotaLens

@MainActor
final class ResetCreditRedemptionTests: XCTestCase {
    private let key = AccountIdentity.stableAccountKey(from: "account-test")
    private func card(_ id: String = "card-test") -> ResetCreditDisplay {
        ResetCreditDisplay(id: id, accountKey: key, title: nil, resetType: nil, status: "available", grantedAt: nil, expiresAt: nil)
    }
    private func response(_ body: String) throws -> JSONRPCResponse {
        try JSONDecoder().decode(JSONRPCResponse.self, from: Data(body.utf8))
    }
    private var account: String { #"{"id":1,"result":{"account":{"type":"chatgpt","accountId":"account-test","email":"secret@example.com"}}}"# }
    private var limits: String { #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"card-test","status":"available"}]}}}"# }

    func testSubmissionFailureAlwaysReturnsRecognizedError() async throws {
        for body in [#"{"result":{}}"#, #"{"result":{"outcome":"unknown"}}"#, #"{"error":{"code":-32000,"message":"failed"}}"#] {
            var persisted = false
            do {
                _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                    idempotencyKey: "attempt", isCurrentAccount: { true }, willSubmit: { persisted = true },
                    send: { method, _ in
                        if method == "account/read" { return try self.response(self.account) }
                        if method == "account/rateLimits/read" { return try self.response(self.limits) }
                        XCTAssertTrue(persisted)
                        return try self.response(body)
                    })
                XCTFail("Expected unconfirmed result")
            } catch {
                XCTAssertEqual(error as? ResetCreditUseError, .uncertain)
                XCTAssertNotNil((error as? ResetCreditUseError)?.errorDescription)
            }
        }
    }

    func testAllOutcomesReturnWithoutWaitingForRefresh() async throws {
        for outcome in ["reset", "alreadyRedeemed", "noCredit", "nothingToReset"] {
            var methods: [String] = []
            let result = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                idempotencyKey: "same-attempt", isCurrentAccount: { true }, send: { method, params in
                    methods.append(method)
                    if method == "account/read" { return try self.response(self.account) }
                    if method == "account/rateLimits/read" { return try self.response(self.limits) }
                    let encoded = try JSONEncoder().encode(params)
                    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: String]
                    XCTAssertEqual(object, ["creditId": "card-test", "idempotencyKey": "same-attempt"])
                    return try self.response("{\"result\":{\"outcome\":\"\(outcome)\"}}")
                })
            XCTAssertEqual(result.rawValue, outcome)
            XCTAssertEqual(methods, ["account/read", "account/rateLimits/read", ConsumeRateLimitResetCreditRequest.method])
        }
    }

    func testUnsupportedIsOnlyReportedForMethodNotFound() async throws {
        for (code, expected) in [(-32601, ResetCreditUseError.unsupported), (-32602, .incompatible), (-32000, .uncertain)] {
            do {
                _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                    idempotencyKey: "attempt", isCurrentAccount: { true }, send: { method, _ in
                        if method == "account/read" { return try self.response(self.account) }
                        if method == "account/rateLimits/read" { return try self.response(self.limits) }
                        return try self.response("{\"error\":{\"code\":\(code),\"message\":\"test\"}}")
                    })
                XCTFail("Expected error")
            } catch { XCTAssertEqual(error as? ResetCreditUseError, expected) }
        }
    }

    func testSyntheticAndStaleCardsNeverSubmit() async throws {
        for id in ["reset_credit_0_0_0", "missing", ""] {
            var submitted = false
            do {
                _ = try await ResetCreditRedemption.consume(credit: card(id), accountKey: key, accountEmailHash: nil,
                    idempotencyKey: "attempt", isCurrentAccount: { true }, send: { method, _ in
                        if method == ConsumeRateLimitResetCreditRequest.method { submitted = true }
                        return try self.response(method == "account/read" ? self.account : self.limits)
                    })
                XCTFail("Expected unavailable")
            } catch { XCTAssertEqual(error as? ResetCreditUseError, .unavailable) }
            XCTAssertFalse(submitted)
        }
    }

    func testTransportThrownMethodNotFoundIsUnsupported() async throws {
        do {
            _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                idempotencyKey: "attempt", isCurrentAccount: { true }, send: { method, _ in
                    if method == "account/read" { return try self.response(self.account) }
                    if method == "account/rateLimits/read" { return try self.response(self.limits) }
                    throw NSError(domain: "JSONRPCTransport", code: -32601,
                        userInfo: [NSLocalizedDescriptionKey: "Method not found"])
                })
            XCTFail("Expected unsupported")
        } catch { XCTAssertEqual(error as? ResetCreditUseError, .unsupported) }
    }

    func testWrongConnectedAccountNeverSubmits() async throws {
        var methods: [String] = []
        do {
            _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                idempotencyKey: "attempt", isCurrentAccount: { true }, send: { method, _ in
                    methods.append(method)
                    return try self.response(self.account.replacingOccurrences(of: "account-test", with: "other-account"))
                })
            XCTFail("Expected mismatch")
        } catch { XCTAssertEqual(error as? ResetCreditUseError, .accountChanged) }
        XCTAssertEqual(methods, ["account/read"])
    }

    func testAccountSwitchDuringPreflightNeverSubmits() async throws {
        var current = true
        do {
            _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                idempotencyKey: "attempt", isCurrentAccount: { current }, send: { method, _ in
                    XCTAssertNotEqual(method, ConsumeRateLimitResetCreditRequest.method)
                    if method == "account/read" { return try self.response(self.account) }
                    current = false
                    return try self.response(self.limits)
                })
            XCTFail("Expected mismatch")
        } catch { XCTAssertEqual(error as? ResetCreditUseError, .accountChanged) }
    }

    func testTimeoutIsUncertainAndDoesNotAutomaticallyRedeemAgain() async throws {
        var submissions = 0
        do {
            _ = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
                idempotencyKey: "attempt", isCurrentAccount: { true }, send: { method, _ in
                    if method == "account/read" { return try self.response(self.account) }
                    if method == "account/rateLimits/read" { return try self.response(self.limits) }
                    submissions += 1
                    throw JSONRPCTransportError.timedOut(method: method)
                })
            XCTFail("Expected uncertain")
        } catch { XCTAssertEqual(error as? ResetCreditUseError, .uncertain) }
        XCTAssertEqual(submissions, 1)
    }

    func testRetryCanConfirmCardAlreadyRemovedByTimedOutReset() async throws {
        let result = try await ResetCreditRedemption.consume(credit: card(), accountKey: key, accountEmailHash: nil,
            idempotencyKey: "persisted-attempt", isRetry: true, isCurrentAccount: { true }, send: { method, params in
                if method == "account/read" { return try self.response(self.account) }
                if method == "account/rateLimits/read" { return try self.response(#"{"result":{"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}"#) }
                XCTAssertTrue(String(decoding: try JSONEncoder().encode(params), as: UTF8.self).contains("persisted-attempt"))
                return try self.response(#"{"result":{"outcome":"alreadyRedeemed"}}"#)
            })
        XCTAssertEqual(result, .alreadyRedeemed)
    }

}
