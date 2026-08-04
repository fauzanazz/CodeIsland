import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class TerminalTextInjectionTests: XCTestCase {
    private func makeSession(
        termBundleId: String?,
        source: String = "claude",
        remoteHostId: String? = nil
    ) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = source
        session.termBundleId = termBundleId
        session.remoteHostId = remoteHostId
        return session
    }

    func testOnlyLocalRecognizedTerminalsAllowTextInjection() {
        XCTAssertTrue(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: "com.googlecode.iterm2")
        ))
        XCTAssertTrue(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: "com.cmuxterm.app")
        ))
        XCTAssertFalse(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: "com.todesktop.230313mzl4w4u92", source: "cursor")
        ))
        XCTAssertFalse(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: "com.microsoft.VSCode")
        ))
        XCTAssertFalse(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: nil)
        ))
        XCTAssertFalse(TerminalActivator.canInjectText(
            into: makeSession(termBundleId: "com.googlecode.iterm2", remoteHostId: "mac-mini")
        ))
    }
}
