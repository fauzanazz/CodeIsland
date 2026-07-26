import XCTest
@testable import CodeIslandCore

final class PiAgentEventFlowTests: XCTestCase {
    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    private func apply(_ payload: [String: Any], to sessions: inout [String: SessionSnapshot]) throws -> [SideEffect] {
        reduceEvent(sessions: &sessions, event: try hookEvent(payload), maxHistory: 20)
    }

    func testPiSessionStartPreservesDirectPluginEnvForHarnessJumping() throws {
        let sessionId = "pi-e2e-env"
        var sessions: [String: SessionSnapshot] = [:]

        let effects = try apply([
            "hook_event_name": "SessionStart",
            "session_id": sessionId,
            "_source": "pi",
            "_ppid": 12345,
            "cwd": "/Users/dev/workspace",
            "session_title": "Pi env test",
            "_env": [
                "TERM_PROGRAM": "Ghostty",
                "__CFBundleIdentifier": "com.mitchellh.ghostty",
                "ITERM_SESSION_ID": "w0t0p0:GUID-123",
                "TMUX": "/tmp/tmux-501/default,111,0",
                "TMUX_PANE": "%42",
                "KITTY_WINDOW_ID": "kitty-7",
                "CMUX_SURFACE_ID": "surface-123",
                "CMUX_WORKSPACE_ID": "workspace-456",
                "ZELLIJ_PANE_ID": "17",
                "ZELLIJ_SESSION_NAME": "zed",
                "WEZTERM_PANE": "99",
            ],
        ], to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.source, "pi")
        XCTAssertEqual(session.cwd, "/Users/dev/workspace")
        XCTAssertEqual(session.sessionTitle, "Pi env test")
        XCTAssertEqual(session.cliPid, 12345)
        XCTAssertEqual(session.termApp, "Ghostty")
        XCTAssertEqual(session.termBundleId, "com.mitchellh.ghostty")
        XCTAssertEqual(session.itermSessionId, "GUID-123")
        XCTAssertEqual(session.tmuxEnv, "/tmp/tmux-501/default,111,0")
        XCTAssertEqual(session.tmuxPane, "%42")
        XCTAssertEqual(session.kittyWindowId, "kitty-7")
        XCTAssertEqual(session.cmuxSurfaceId, "surface-123")
        XCTAssertEqual(session.cmuxWorkspaceId, "workspace-456")
        XCTAssertEqual(session.zellijPaneId, "17")
        XCTAssertEqual(session.zellijSessionName, "zed")
        XCTAssertEqual(session.weztermPaneId, "99")
        XCTAssertTrue(effects.contains(.stopMonitor(sessionId: sessionId)))
        XCTAssertTrue(effects.contains(.tryMonitorSession(sessionId: sessionId)))
    }
    func testPiAndOmpAliasesNormalizeToPi() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("pi"), "pi")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("omp"), "pi")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("Oh My Pi"), "pi")

        var session = SessionSnapshot()
        session.source = "pi"
        XCTAssertEqual(session.sourceLabel, "Pi")
    }

    func testPiAgentLifecyclePayloadsReduceToVisibleSessionState() throws {
        let sessionId = "pi-e2e-flow"
        var sessions: [String: SessionSnapshot] = [:]
        let base: [String: Any] = [
            "session_id": sessionId,
            "_source": "pi",
            "_ppid": 22222,
            "cwd": "/Users/dev/project",
            "_env": ["TERM_PROGRAM": "Apple_Terminal"],
        ]

        _ = try apply(base.merging(["hook_event_name": "SessionStart"]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging([
            "hook_event_name": "UserPromptSubmit",
            "prompt": "Fix the Pi harness status panel",
        ]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging([
            "hook_event_name": "PreToolUse",
            "tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/AGENTS.md"],
        ]) { _, new in new }, to: &sessions)
        _ = try apply(base.merging(["hook_event_name": "PostToolUse"]) { _, new in new }, to: &sessions)
        let stopEffects = try apply(base.merging([
            "hook_event_name": "Stop",
            "last_assistant_message": "Pi harness status is wired.",
        ]) { _, new in new }, to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.source, "pi")
        XCTAssertEqual(session.lastUserPrompt, "Fix the Pi harness status panel")
        XCTAssertEqual(session.lastAssistantMessage, "Pi harness status is wired.")
        XCTAssertNil(session.currentTool)
        XCTAssertEqual(session.toolHistory.count, 1)
        XCTAssertEqual(session.toolHistory.first?.tool, "Read")
        XCTAssertEqual(session.toolHistory.first?.description, "AGENTS.md")
        XCTAssertEqual(session.recentMessages.map(\.text), [
            "Fix the Pi harness status panel",
            "Pi harness status is wired.",
        ])
        XCTAssertTrue(stopEffects.contains(.enqueueCompletion(sessionId: sessionId)))
    }

    func testUsagePayloadPopulatesSessionUsage() throws {
        let sessionId = "pi-usage"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "PostToolUse",
            "session_id": sessionId,
            "_source": "omp",
            "cwd": "/tmp/x",
            "usage": [
                "input": 42,
                "output": 1337,
                "cacheRead": 900,
                "cacheWrite": 5000,
                "totalTokens": 7279,
                "cost": 0.1234,
                "contextTokens": 32000,
                "contextWindow": 200000,
                "contextPct": 0.16,
            ],
        ], to: &sessions)

        let usage = try XCTUnwrap(sessions[sessionId]?.usage)
        XCTAssertEqual(usage.input, 42)
        XCTAssertEqual(usage.output, 1337)
        XCTAssertEqual(usage.cacheRead, 900)
        XCTAssertEqual(usage.cacheWrite, 5000)
        XCTAssertEqual(usage.totalTokens, 7279)
        XCTAssertEqual(usage.cost, 0.1234, accuracy: 1e-9)
        XCTAssertEqual(usage.contextTokens, 32000)
        XCTAssertEqual(usage.contextWindow, 200000)
        XCTAssertEqual(usage.contextPct, 0.16, accuracy: 1e-9)
    }

    func testMissingUsageKeysPreservePriorTotals() throws {
        let sessionId = "pi-usage-merge"
        var sessions: [String: SessionSnapshot] = [:]

        _ = try apply([
            "hook_event_name": "PreToolUse",
            "session_id": sessionId,
            "_source": "omp",
            "usage": ["input": 10, "output": 20, "totalTokens": 30],
        ], to: &sessions)
        // A later event with only context info must not zero out token totals.
        _ = try apply([
            "hook_event_name": "PostToolUse",
            "session_id": sessionId,
            "_source": "omp",
            "usage": ["contextTokens": 100, "contextWindow": 1000, "contextPct": 0.1],
        ], to: &sessions)

        let usage = try XCTUnwrap(sessions[sessionId]?.usage)
        XCTAssertEqual(usage.input, 10)
        XCTAssertEqual(usage.output, 20)
        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.contextTokens, 100)
        XCTAssertEqual(usage.contextWindow, 1000)
    }
}
