import Foundation
import Testing
@testable import TreadmillKit

private func ok(_ op: UInt8) -> ControlResponse { ControlResponse(requestOpcode: op, result: .success, rawResult: 1) }
private func denied(_ op: UInt8) -> ControlResponse { ControlResponse(requestOpcode: op, result: .notPermitted, rawResult: 5) }

@Suite struct ControlQueueTests {
    @Test func requestsControlFirst() {
        var q = ControlQueue()
        q.enqueue(.setSpeed(3))
        #expect(q.next() == .requestControl)
        #expect(q.next() == nil) // waits for the answer
        #expect(q.handle(ok(0x00)) == .done(.requestControl))
        #expect(q.next() == .setSpeed(3))
        #expect(q.handle(ok(0x02)) == .done(.setSpeed(3)))
        #expect(q.isIdle)
    }

    @Test func fastSpeedClicksCollapse() {
        var q = ControlQueue()
        q.hasControl = true
        q.enqueue(.setSpeed(3.1))
        #expect(q.next() == .setSpeed(3.1))
        for v in [3.2, 3.3, 3.4, 3.5] { q.enqueue(.setSpeed(v)) } // clicked while 3.1 is in flight
        #expect(q.pending == [.setSpeed(3.5)])
        #expect(q.pendingSpeed == 3.5)
        _ = q.handle(ok(0x02))
        #expect(q.next() == .setSpeed(3.5))
    }

    @Test func stopJumpsTheQueue() {
        var q = ControlQueue()
        q.hasControl = true
        q.enqueue(.setSpeed(5))
        q.enqueue(.pause)
        q.enqueue(.stop)
        #expect(q.pending == [.stop])
    }

    @Test func pauseDropsPendingSpeed() {
        var q = ControlQueue()
        q.hasControl = true
        q.enqueue(.setSpeed(5))
        q.enqueue(.pause)
        q.enqueue(.pause)
        #expect(q.pending == [.pause])
    }

    /// After Stop the treadmill reset and answered "not permitted": the next command asks for control.
    @Test func notPermittedMakesTheNextCommandAskForControl() {
        var q = ControlQueue()
        q.hasControl = true
        q.enqueue(.setSpeed(3.9))
        #expect(q.next() == .setSpeed(3.9))
        #expect(q.handle(denied(0x02)) == .failed(.setSpeed(3.9), denied(0x02)))
        #expect(q.isIdle) // no automatic retry: BeltController decides
        q.enqueue(.startOrResume)
        #expect(q.next() == .requestControl)
        _ = q.handle(ok(0x00))
        #expect(q.next() == .startOrResume)
    }

    @Test func timeoutFreesTheQueue() {
        var q = ControlQueue()
        q.hasControl = true
        let t0 = Date()
        q.enqueue(.pause)
        q.enqueue(.setSpeed(3)) // after pause
        #expect(q.next(now: t0) == .pause)
        #expect(q.next(now: t0.addingTimeInterval(1)) == nil)
        #expect(q.expire(now: t0.addingTimeInterval(2)) == .pause)
        #expect(q.next(now: t0.addingTimeInterval(2)) == .setSpeed(3))
    }

    @Test func refusedControlClearsQueue() {
        var q = ControlQueue()
        q.enqueue(.setSpeed(3))
        _ = q.next()
        #expect(q.handle(denied(0x00)) == .failed(.requestControl, denied(0x00)))
        #expect(q.isIdle)
    }

    @Test func unsolicitedResponseIgnored() {
        var q = ControlQueue()
        #expect(q.handle(ok(0x02)) == .ignored)
    }
}
