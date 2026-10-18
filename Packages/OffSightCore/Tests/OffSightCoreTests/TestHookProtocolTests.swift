import XCTest
@testable import OffSightCore

final class TestHookProtocolTests: XCTestCase {
    func testCommandsRoundTrip() {
        let commands: [TestHook.Command] = [
            .state, .approve(app: "*"), .approve(app: "com.apple.PhotoBooth"), .keepPlaceholder(app: "us.zoom.xos"),
            .closeAllShutters, .pause(minutes: 1), .resume, .setPromptExpiry(seconds: 5), .setGracePeriod(seconds: 7.5),
        ]
        for command in commands {
            XCTAssertEqual(TestHook.Command(encoded: command.encoded), command, command.encoded)
        }
    }

    func testBadCommandsAreRejected() {
        for bad in ["", "approve", "approve:", "pause:0", "pause:x", "setGrace:abc", "unknown", "keep:"] {
            XCTAssertNil(TestHook.Command(encoded: bad), bad)
        }
    }

    func testStateRoundTrip() {
        let state = TestHookState(time: 1_700_000_000.25, live: true, paused: false, protectionState: "live",
                                  sessions: [.init(app: "a", name: "A", phase: "live", startedAt: 1)],
                                  prompts: [.init(app: "b", name: "B", shownAt: 2)], extensionConnected: true,
                                  cameraFormat: "2560x1440", promptExpiry: 30, gracePeriod: 15,
                                  liveFramesSent: 10, placeholderFramesSent: 20, recentEvents: ["x"])
        XCTAssertEqual(TestHookState.decode(state.encodedJSON), state)
        XCTAssertNil(TestHookState.decode("not json"))
    }
}
