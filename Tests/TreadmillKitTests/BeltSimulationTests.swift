import Foundation
import Testing
@testable import TreadmillKit

/// A simulated X218 that follows the rules seen on the real treadmill:
/// - Start (07) refused while the belt still moves; then a 4 s countdown and "started or resumed";
/// - Pause (08 02) only while running (refused during the countdown here: the real answer is unknown,
///   so the simulation takes the stricter one);
/// - Stop (08 01) refused while the belt moves; after Stop the treadmill resets and drops control;
/// - Set Target Speed (02) only while running (also while speeding up);
/// - the belt changes speed by about 1 km/h per second.
private struct FakeX218 {
    enum State: Equatable { case stopped, paused, countdown(until: Double), running }

    var state: State = .stopped
    var speed = 0.0
    var target = 1.0
    var hasControl = false
    var t = 0.0
    var elapsed = 0.0
    var statuses: [MachineStatus] = []
    var refused: [ControlCommand] = []
    var accepted: [ControlCommand] = []

    mutating func handle(_ cmd: ControlCommand) -> ControlResponse.Result {
        let r = decide(cmd)
        if r == .success { accepted.append(cmd) } else { refused.append(cmd) }
        return r
    }

    private mutating func decide(_ cmd: ControlCommand) -> ControlResponse.Result {
        if cmd == .requestControl { hasControl = true; return .success }
        guard hasControl else { return .notPermitted }
        switch cmd {
        case .startOrResume:
            guard state == .stopped || state == .paused, speed == 0 else { return .notPermitted }
            state = .countdown(until: t + 4)
            return .success
        case .pause:
            guard state == .running else { return .notPermitted }
            state = .paused
            statuses.append(.pausedByUser)
            return .success
        case .stop:
            guard state == .paused || state == .stopped, speed == 0 else { return .notPermitted }
            state = .stopped
            elapsed = 0
            hasControl = false
            statuses.append(.reset)
            return .success
        case .setSpeed(let v):
            guard state == .running else { return .notPermitted }
            target = v
            statuses.append(.targetSpeedChanged(v))
            return .success
        default:
            return .notSupported
        }
    }

    mutating func tick(_ dt: Double) {
        t += dt
        switch state {
        case .countdown(let until):
            if t >= until {
                state = .running
                statuses.append(.startedOrResumed)
            }
        case .running:
            elapsed += dt
            speed = speed < target ? min(target, speed + dt) : max(target, speed - dt)
        case .paused, .stopped:
            speed = max(0, speed - dt)
        }
    }
}

/// Wires the fake treadmill, the queue and the controller exactly like TreadmillManager does.
private struct Rig {
    var tm = FakeX218()
    var q = ControlQueue()
    var c = BeltController()
    var now = Date(timeIntervalSince1970: 0)

    mutating func step(_ dt: Double = 0.1) {
        now = now.addingTimeInterval(dt)
        tm.tick(dt)
        for s in tm.statuses {
            c.observe(status: s, now: now)
            if s == .reset { q.controlLost() }
        }
        tm.statuses.removeAll()
        c.observe(speed: (tm.speed * 10).rounded() / 10, elapsed: Int(tm.elapsed), now: now)
        if q.isIdle, let cmd = c.next(now: now) { q.enqueue(cmd) }
        if let cmd = q.next(now: now) {
            let result = tm.handle(cmd)
            _ = q.handle(ControlResponse(requestOpcode: cmd.opcode, result: result, rawResult: result.rawValue))
            if cmd != .requestControl { c.observe(response: cmd, result: result, now: now) }
        }
    }

    mutating func run(_ seconds: Double) {
        for _ in 0..<Int(seconds * 10) { step() }
    }

    mutating func runningAt(_ v: Double) {
        c.user(.run(v))
        run(12)
    }

    /// Belt commands refused by the treadmill (Request Control does not count).
    var refusals: Int { tm.refused.filter { $0 != .requestControl }.count }
}

@Suite struct BeltSimulationTests {
    @Test func startFromStopped() {
        var r = Rig()
        r.runningAt(3)
        #expect(r.tm.state == .running)
        #expect(r.tm.target == 3)
        #expect(r.c.intent == .none)
        #expect(r.refusals == 0)
    }

    @Test func stopWhileRunningPausesFirst() {
        var r = Rig()
        r.runningAt(4)
        r.c.user(.stop)
        r.run(10)
        #expect(r.tm.state == .stopped)
        #expect(r.c.phase == .stopped)
        #expect(r.c.failure == nil)
        #expect(r.refusals == 0) // never sends Stop to a moving belt
        #expect(r.tm.accepted.suffix(2) == [.pause, .stop])
    }

    @Test func resumeRightAfterPauseWaitsForStandstill() {
        var r = Rig()
        r.runningAt(3)
        r.c.user(.pause)
        r.run(0.5)
        #expect(r.c.slowingDown)
        r.c.user(.run(3)) // the click that failed live at 16:50:47
        #expect(r.c.waitsForStandstill)
        r.run(12)
        #expect(r.tm.state == .running)
        #expect(r.tm.target == 3)
        #expect(r.refusals == 0)
    }

    @Test func stopDuringCountdown() {
        var r = Rig()
        r.c.user(.run(3))
        r.run(1)
        #expect(r.c.isStarting)
        r.c.user(.stop)
        r.run(20)
        #expect(r.tm.state == .stopped)
        #expect(r.c.intent == .none)
        #expect(r.c.failure == nil)
    }

    @Test func speedClicksDuringCountdownEndAtTheLastOne() {
        var r = Rig()
        r.c.user(.run(3))
        r.run(1)
        for v in [3.5, 4.0, 4.5, 4.0] { r.c.user(.run(v)); r.step() }
        r.run(12)
        #expect(r.tm.state == .running)
        #expect(r.tm.target == 4.0)
        #expect(r.refusals == 0)
    }

    @Test func startRightAfterStopWaitsAndStarts() {
        var r = Rig()
        r.runningAt(5)
        r.c.user(.stop)
        r.run(0.3)
        r.c.user(.run(3)) // changed mind while the belt slows down
        r.run(15)
        #expect(r.tm.state == .running)
        #expect(r.tm.target == 3)
        #expect(r.c.failure == nil)
    }

    @Test func doublePauseSendsOnePause() {
        var r = Rig()
        r.runningAt(3)
        r.c.user(.pause)
        r.step()
        r.c.user(.pause)
        r.run(5)
        #expect(r.tm.accepted.filter { $0 == .pause }.count == 1)
        #expect(r.refusals == 0)
    }

    @Test func startAfterResetAsksForControlAgain() {
        var r = Rig()
        r.runningAt(3)
        r.c.user(.stop)
        r.run(10)
        #expect(!r.tm.hasControl)
        r.runningAt(3)
        #expect(r.tm.state == .running)
        #expect(r.refusals == 0)
    }

    @Test func mashingEverythingConverges() {
        var r = Rig()
        let clicks: [BeltController.Intent] = [.run(3), .pause, .run(3), .stop, .run(4), .pause, .run(5), .stop, .run(3.5)]
        for c in clicks { r.c.user(c); r.run(0.3) }
        r.run(25)
        #expect(r.tm.state == .running)
        #expect(r.tm.target == 3.5)
        #expect(r.c.failure == nil)
    }

    @Test func beltStartedFromTheTreadmillItselfIsRecognised() {
        var r = Rig()
        r.run(1)
        #expect(r.c.phase == .stopped)
        // Remote/console start: the controller sent nothing.
        r.tm.hasControl = true
        _ = r.tm.handle(.startOrResume)
        r.run(8)
        #expect(r.c.phase == .running)
    }

    @Test func giveUpAfterRepeatedRefusals() {
        var c = BeltController()
        c.maxAttempts = 3
        var now = Date(timeIntervalSince1970: 0)
        c.observe(speed: 0, elapsed: 0, now: now)
        c.user(.run(3))
        for _ in 0..<10 {
            if let cmd = c.next(now: now) { c.observe(response: cmd, result: .notPermitted, now: now) }
            now = now.addingTimeInterval(1)
        }
        #expect(c.failure != nil)
        #expect(c.intent == .none)
    }
}
