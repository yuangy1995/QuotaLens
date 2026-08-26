import XCTest
@testable import QuotaLens

final class ParserRecoveryTests: XCTestCase {
    func testDecoderAcceptsCompactWhitespaceReorderedAndBOMJSON() throws {
        let compact = "{\"type\":\"token_count\",\"timestamp\":1787227200,\"payload\":{\"model\":\"gpt-5.6-luna\",\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":2,\"output_tokens\":5}}}"
        let spaced = "{ \"payload\" : { \"last_token_usage\" : { \"output_tokens\" : 5, \"input_tokens\" : 10 }, \"model\" : \"gpt-5.4\" }, \"type\" : \"token_count\" }"
        let reordered = "{\"padding\":1,\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":9,\"output_tokens\":3}}},\"type\":\"event_msg\"}"

        for line in [compact, spaced, reordered, "\u{feff}" + compact] {
            let event = try XCTUnwrap(RolloutLineDecoder.decodeLine(line))
            XCTAssertNotNil(event.lastTokenUsage)
        }
        XCTAssertEqual(RolloutLineDecoder.decodeLine(compact)?.timestampMs, 1_787_227_200_000)
        XCTAssertEqual(RolloutLineDecoder.decodeLine(spaced)?.timestampQuality, .unresolved)
    }

    func testDecoderAcceptsLegacyTopLevelTokenBucketsAndEpochTimestamp() throws {
        let legacy = "{\"event\":\"token_count\",\"created_at\":1787227200,\"model\":\"gpt-5.3-codex\",\"input_tokens\":\"7\",\"cached_input_tokens\":2,\"output_tokens\":3}"
        let event = try XCTUnwrap(RolloutLineDecoder.decodeLine(legacy))
        XCTAssertEqual(event.timestampMs, 1_787_227_200_000)
        XCTAssertEqual(event.model, "gpt-5.3-codex")
        XCTAssertEqual(event.lastTokenUsage?.inputTokens, 7)
        XCTAssertEqual(event.lastTokenUsage?.cachedInputTokens, 2)
        XCTAssertEqual(event.lastTokenUsage?.outputTokens, 3)
    }

    func testCacheWriteTokensAreParsedAndDifferencedAcrossAllBuckets() throws {
        let creationLine = "{\"event\":\"token_count\",\"created_at\":1787227200,\"model\":\"gpt-5.6-sol\",\"input_tokens\":10,\"cached_input_tokens\":2,\"cache_creation_input_tokens\":3,\"output_tokens\":4}"
        let creationEvent = try XCTUnwrap(RolloutLineDecoder.decodeLine(creationLine))
        XCTAssertEqual(creationEvent.lastTokenUsage?.inputTokens, 10)
        XCTAssertEqual(creationEvent.lastTokenUsage?.cachedInputTokens, 2)
        XCTAssertEqual(creationEvent.lastTokenUsage?.cacheWriteInputTokens, 3)
        XCTAssertEqual(creationEvent.lastTokenUsage?.outputTokens, 4)

        let reducer = CodexUsageReducer(
            sessionId: "session",
            rootSessionId: "session",
            isChildSession: false,
            sourcePath: "/tmp/rollout.jsonl"
        )
        var state = CodexUsageReducer.ReducerState()
        _ = reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 1,
                totalTokenUsage: RawTokenUsagePayload(
                    inputTokens: 10,
                    cachedInputTokens: 2,
                    cacheWriteInputTokens: 3,
                    outputTokens: 4
                )
            ),
            lineRecord: lineRecord(index: 0),
            state: &state
        )
        let delta = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 2,
                totalTokenUsage: RawTokenUsagePayload(
                    inputTokens: 15,
                    cachedInputTokens: 4,
                    cacheWriteInputTokens: 6,
                    outputTokens: 7
                )
            ),
            lineRecord: lineRecord(index: 1),
            state: &state
        ))
        XCTAssertEqual(delta.tokens.inputTokens, 5)
        XCTAssertEqual(delta.tokens.cachedInputTokens, 2)
        XCTAssertEqual(delta.tokens.cacheWriteInputTokens, 3)
        XCTAssertEqual(delta.tokens.uncachedInputTokens, 0)
        XCTAssertEqual(delta.tokens.outputTokens, 3)
        XCTAssertEqual(state.makeCheckpoint().lastCumulativeCacheWrite, 6)

        let alternateSpelling = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":8,\"cache_write_input_tokens\":5}}}}"
        XCTAssertEqual(RolloutLineDecoder.decodeLine(alternateSpelling)?.lastTokenUsage?.cacheWriteInputTokens, 5)
    }

    func testStreamingReaderFindsTypeAfter8KBAndBeyond1MBWithCRLF() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("long.jsonl")
        let padding = String(repeating: "x", count: 1_100_000)
        let line = "{\"padding\":\"\(padding)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":7,\"output_tokens\":2}}}}\r\n"
        try overwriteFile(file, with: line)

        var decoded: [RolloutWireEvent] = []
        let result = try StreamingJSONLReader.readLines(
            fileURL: file,
            chunkSize: 64 * 1024,
            shouldIncludeLineData: RolloutLineDecoder.mayContainUsageRelevantEvent
        ) { record in
            if let event = RolloutLineDecoder.decodeLine(record.lineString) {
                decoded.append(event)
            }
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.lastTokenUsage?.inputTokens, 7)
        XCTAssertEqual(result.finalOffset, Int64(line.utf8.count))
    }

    func testReaderCommitsValidNoNewlineEOFAndRetainsPartialEOF() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("partial.jsonl")
        let complete = "{\"type\":\"token_count\",\"payload\":{\"last_token_usage\":{\"input_tokens\":1}}}\n"
        let partialPrefix = "{\"type\":\"token_count\",\"payload\":{\"last_token_usage\":"
        try overwriteFile(file, with: complete + partialPrefix)

        var firstPass = 0
        let firstResult = try StreamingJSONLReader.readLines(fileURL: file) { _ in firstPass += 1 }
        XCTAssertEqual(firstPass, 1)
        XCTAssertEqual(firstResult.finalOffset, Int64(complete.utf8.count))

        try appendFile(file, with: "{\"input_tokens\":2}}}")
        var secondPass = 0
        let secondResult = try StreamingJSONLReader.readLines(fileURL: file, startOffset: firstResult.finalOffset) { record in
            secondPass += 1
            XCTAssertNotNil(RolloutLineDecoder.decodeLine(record.lineString))
        }
        XCTAssertEqual(secondPass, 1)
        XCTAssertEqual(secondResult.finalOffset, Int64((complete + partialPrefix + "{\"input_tokens\":2}}}").utf8.count))
    }

    func testUnknownModelUsesExplicitUnpricedIdentity() throws {
        let reducer = CodexUsageReducer(
            sessionId: "session",
            rootSessionId: "session",
            isChildSession: false,
            sourcePath: "/tmp/rollout.jsonl",
            fallbackTimestampMs: 1_800_000_000_000,
            fallbackTimestampQuality: .fileModificationTime
        )
        var state = CodexUsageReducer.ReducerState()
        let parsed = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 0,
                timestampQuality: .unresolved,
                lastTokenUsage: RawTokenUsagePayload(inputTokens: 10, outputTokens: 5)
            ),
            lineRecord: lineRecord(index: 0),
            state: &state
        ))
        XCTAssertEqual(parsed.modelRaw, "unknown")
        XCTAssertEqual(parsed.modelCanonical, "unknown")
        XCTAssertEqual(parsed.attributionQuality, .unknownDefault)
        XCTAssertEqual(parsed.timestampQuality, .fileModificationTime)
    }

    func testUnresolvedTimestampDoesNotEmitButAdvancesCumulativeBaseline() throws {
        let reducer = CodexUsageReducer(
            sessionId: "session",
            rootSessionId: "session",
            isChildSession: false,
            sourcePath: "/tmp/rollout.jsonl"
        )
        var state = CodexUsageReducer.ReducerState()
        let skipped = reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 0,
                totalTokenUsage: RawTokenUsagePayload(inputTokens: 100, outputTokens: 20)
            ),
            lineRecord: lineRecord(index: 0),
            state: &state
        )
        XCTAssertNil(skipped)
        let emitted = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 1_800_000_000_000,
                totalTokenUsage: RawTokenUsagePayload(inputTokens: 150, outputTokens: 30)
            ),
            lineRecord: lineRecord(index: 1),
            state: &state
        ))
        XCTAssertEqual(emitted.tokens.inputTokens, 50)
        XCTAssertEqual(emitted.tokens.outputTokens, 10)
    }

    func testCumulativeCachedOnlyChangeAndIndependentRestartArePreserved() throws {
        let reducer = CodexUsageReducer(
            sessionId: "session",
            rootSessionId: "session",
            isChildSession: false,
            sourcePath: "/tmp/rollout.jsonl"
        )
        var state = CodexUsageReducer.ReducerState()
        _ = reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 1,
                totalTokenUsage: RawTokenUsagePayload(inputTokens: 100, cachedInputTokens: 10, outputTokens: 100, reasoningOutputTokens: 50)
            ),
            lineRecord: lineRecord(index: 0),
            state: &state
        )
        let cachedOnly = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 2,
                totalTokenUsage: RawTokenUsagePayload(inputTokens: 100, cachedInputTokens: 20, outputTokens: 100, reasoningOutputTokens: 50)
            ),
            lineRecord: lineRecord(index: 1),
            state: &state
        ))
        XCTAssertEqual(cachedOnly.tokens.inputTokens, 10)
        XCTAssertEqual(cachedOnly.tokens.cachedInputTokens, 10)

        let restarted = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 3,
                totalTokenUsage: RawTokenUsagePayload(inputTokens: 120, cachedInputTokens: 20, outputTokens: 10, reasoningOutputTokens: 5)
            ),
            lineRecord: lineRecord(index: 2),
            state: &state
        ))
        XCTAssertEqual(restarted.usageDerivation, .totalUsageRestart)
        XCTAssertEqual(restarted.tokens.inputTokens, 20)
        XCTAssertEqual(restarted.tokens.outputTokens, 10)
        XCTAssertEqual(restarted.tokens.reasoningOutputTokens, 5)
    }

    func testReplayStateSurvivesCheckpointResume() throws {
        let reducer = CodexUsageReducer(
            sessionId: "child",
            rootSessionId: "parent",
            isChildSession: true,
            sourcePath: "/tmp/child.jsonl"
        )
        var firstState = CodexUsageReducer.ReducerState()
        _ = reducer.reduce(
            event: RolloutWireEvent(
                eventType: "session_meta",
                timestampMs: 2,
                replayBoundaryTimestampMs: 2,
                sessionId: "child",
                parentSessionId: "parent",
                isChildSessionMeta: true
            ),
            lineRecord: lineRecord(index: 0),
            state: &firstState
        )
        let replay = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 1,
                lastTokenUsage: RawTokenUsagePayload(inputTokens: 5)
            ),
            lineRecord: lineRecord(index: 1),
            state: &firstState
        ))
        XCTAssertTrue(replay.isChildReplay)

        var resumedState = CodexUsageReducer.ReducerState(checkpoint: firstState.makeCheckpoint())
        _ = reducer.reduce(
            event: RolloutWireEvent(eventType: "user_message", timestampMs: 2),
            lineRecord: lineRecord(index: 2),
            state: &resumedState
        )
        XCTAssertFalse(resumedState.makeCheckpoint().hasSeenFreshTurn)
        let fresh = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(
                eventType: "token_count",
                timestampMs: 3,
                lastTokenUsage: RawTokenUsagePayload(inputTokens: 8)
            ),
            lineRecord: lineRecord(index: 3),
            state: &resumedState
        ))
        XCTAssertFalse(fresh.isChildReplay)
        XCTAssertTrue(resumedState.makeCheckpoint().hasSeenFreshTurn)
        XCTAssertEqual(resumedState.makeCheckpoint().parserVersion, ParserCheckpoint.currentParserVersion)
    }

    func testModelAndServiceTierSwitchApplyToFollowingUsage() throws {
        let reducer = CodexUsageReducer(
            sessionId: "session",
            rootSessionId: "session",
            isChildSession: false,
            sourcePath: "/tmp/rollout.jsonl"
        )
        var state = CodexUsageReducer.ReducerState()
        _ = reducer.reduce(
            event: RolloutWireEvent(eventType: "turn_context", timestampMs: 1, model: "gpt-5.4", serviceTier: "flex"),
            lineRecord: lineRecord(index: 0),
            state: &state
        )
        let event = try XCTUnwrap(reducer.reduce(
            event: RolloutWireEvent(eventType: "token_count", timestampMs: 2, lastTokenUsage: RawTokenUsagePayload(inputTokens: 1)),
            lineRecord: lineRecord(index: 1),
            state: &state
        ))
        XCTAssertEqual(event.modelCanonical, "gpt-5.4")
        XCTAssertEqual(event.serviceTier, "flex")
    }

    func testFilenameTimestampAndMissingMetadataNeverUseNow() throws {
        let timestamp = try XCTUnwrap(CodexUsageImportActor.timestampFromFilename(
            "rollout-2026-03-03T18-06-30-abc.jsonl"
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 3)
        XCTAssertEqual(components.hour, 18)

        let resolved = CodexSessionMetadataStore.reconcileSessionTree(
            discoveredIds: ["missing"],
            rawMetadata: [:]
        )
        XCTAssertEqual(resolved["missing"]?.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(resolved["missing"]?.updatedAt, Date(timeIntervalSince1970: 0))
    }

    func testRolloutHeaderExtractsParentAndAgentRole() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("rollout-child.jsonl")
        try overwriteFile(file, with: rolloutText(
            sessionId: "child",
            input: 1,
            output: 1,
            parentSessionId: "parent",
            agentRole: "reviewer"
        ))
        let source = RolloutDiscoveredSource(
            fileURL: file,
            relativePath: "sessions/rollout-child.jsonl",
            bucket: .active,
            sessionId: "child",
            identity: RolloutSourceIdentity(device: 1, inode: 2, birthtimeNs: 3),
            fileSize: Int64((try Data(contentsOf: file)).count),
            mtimeMs: 1
        )
        let header = try XCTUnwrap(CodexSessionMetadataStore.loadFromRolloutHeaders(sources: [source])[file.path])
        XCTAssertEqual(header.metadata?.parentSessionId, "parent")
        XCTAssertEqual(header.metadata?.agentType, "reviewer")
    }

    func testDecoderExtractsReasoningEffortFromTurnContextAndSettings() throws {
        let turnContextLine = "{\"timestamp\":\"2026-08-24T00:57:59.035Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.5\",\"effort\":\"xhigh\",\"collaboration_mode\":{\"mode\":\"default\",\"settings\":{\"model\":\"gpt-5.5\",\"reasoning_effort\":\"xhigh\"}}}}"
        let event1 = try XCTUnwrap(RolloutLineDecoder.decodeLine(turnContextLine))
        XCTAssertEqual(event1.model, "gpt-5.5")
        XCTAssertEqual(event1.reasoningEffort, "xhigh")

        let settingsLine = "{\"type\":\"thread_settings_applied\",\"payload\":{\"thread_settings\":{\"reasoning_effort\":\"high\"}}}"
        let event2 = try XCTUnwrap(RolloutLineDecoder.decodeLine(settingsLine))
        XCTAssertEqual(event2.reasoningEffort, "high")
    }

    func testReducerPropagatesReasoningEffortToParsedUsageEvents() throws {
        let reducer = CodexUsageReducer(
            sessionId: "test-session",
            rootSessionId: "test-session",
            isChildSession: false,
            sourcePath: "/tmp/test.jsonl"
        )
        var state = CodexUsageReducer.ReducerState()

        let turnContext = RolloutWireEvent(
            eventType: "turn_context",
            timestampMs: 1_787_550_000_000,
            model: "gpt-5.6-terra",
            reasoningEffort: "ultra"
        )
        _ = reducer.reduce(event: turnContext, lineRecord: lineRecord(index: 0), state: &state)
        XCTAssertEqual(state.activeReasoningEffort, "ultra")
        XCTAssertEqual(state.activeModel, "gpt-5.6-terra")

        let usageEvent = RolloutWireEvent(
            eventType: "token_count",
            timestampMs: 1_787_550_001_000,
            lastTokenUsage: RawTokenUsagePayload(inputTokens: 100, cachedInputTokens: 20, outputTokens: 50, reasoningOutputTokens: 30)
        )
        let parsed = try XCTUnwrap(reducer.reduce(event: usageEvent, lineRecord: lineRecord(index: 1), state: &state))
        XCTAssertEqual(parsed.modelRaw, "gpt-5.6-terra")
        XCTAssertEqual(parsed.reasoningEffort, "ultra")
        XCTAssertEqual(parsed.tokens.inputTokens, 100)
    }

    func testReasoningEffortDisplayAndBadging() {
        XCTAssertEqual(ReasoningEffortDisplay.badgeText(for: "extra_high"), "xhigh")
        XCTAssertEqual(ReasoningEffortDisplay.badgeText(for: "middle"), "medium")
        XCTAssertEqual(ReasoningEffortDisplay.badgeText(for: "HIGH"), "high")
        XCTAssertEqual(ReasoningEffortDisplay.localizedName(for: "low"), L10n.text("低推理", "Low Reasoning"))
    }

    private func lineRecord(index: Int) -> JSONLLineRecord {
        JSONLLineRecord(
            lineIndex: index,
            startOffset: Int64(index * 100),
            lineBytes: 100,
            lineString: "{}"
        )
    }
}
