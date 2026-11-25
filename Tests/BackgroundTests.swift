import Foundation

@main struct BackgroundTests {
    static func main() async throws {
        var delay = PanelCloseCountdown(delay: 10)
        precondition(!delay.shouldClose(pointerInside: false, now: 100))
        precondition(!delay.shouldClose(pointerInside: true, now: 109))
        precondition(!delay.shouldClose(pointerInside: false, now: 110))
        precondition(delay.shouldClose(pointerInside: false, now: 120))

        var tap = StatusTapSequence()
        precondition(!tap.isDoubleTap(at: 1, count: 1, interval: 0.5))
        precondition(tap.isDoubleTap(at: 1.2, count: 1, interval: 0.5))
        precondition(boundedDiagnosticTail("x🙂z", maxBytes: 4) == "z")

        let snapshot = Data("synthetic session snapshot".utf8)
        let handoff = try IdleHandoff.create(with: snapshot)
        defer { handoff.remove() }
        let restored = try handoff.readSnapshot()
        precondition(restored == snapshot)
        for stage in ["ready", "go", "active"] {
            try handoff.signal(stage)
            try await handoff.waitFor(stage)
        }
        print("PASS: panel timing, tap sequence, log cap, and local session handoff")
    }
}
