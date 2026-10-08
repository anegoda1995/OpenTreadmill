import Foundation

/// Decides which FTMS command to send next so the treadmill ends up where the user asked.
///
/// The user's clicks only set an `Intent` (run at a speed, pause, stop). On every event the controller
/// compares the intent with the belt's phase and returns one command the treadmill accepts in that
/// phase, or nothing (wait). How the X218 behaves:
/// - Start/Resume (07) is refused while the belt still moves (slowing down after Pause);
/// - Stop (08 01) is refused while the belt moves: pause first, stop once it stands still;
/// - Set Target Speed (02) is refused on a stopped or paused belt, accepted while it speeds up;
/// - after Start there is a countdown of about 4 s, then the status "started or resumed";
/// - after Stop the treadmill resets and forgets who has control (ControlQueue asks again).
/// A refused command is not an error by itself: the controller waits for the next state change or
/// for `retryDelay`, and gives up only after `maxAttempts` tries for the same intent.
public struct BeltController: Sendable {
    public enum Phase: Equatable, Sendable { case unknown, stopped, paused, starting, running }
    public enum Intent: Equatable, Sendable { case none, run(Double), pause, stop }

    public private(set) var phase: Phase = .unknown
    public private(set) var intent: Intent = .none
    /// Measured belt speed, km/h.
    public private(set) var speed: Double = 0
    /// Last target the treadmill accepted or announced.
    public private(set) var acceptedSpeed: Double?
    public private(set) var failure: String?

    public var retryDelay: TimeInterval = 0.8
    /// The belt must stand still this long before Start or Stop (one Stop was refused right at 0 km/h).
    public var settleTime: TimeInterval = 0.6
    public var countdownTimeout: TimeInterval = 8
    public var maxAttempts = 10

    private var waitUntil: Date?
    private var attempts = 0
    private var startAcceptedAt: Date?
    private var lastElapsed = 0
    private var phaseChangedAt = Date.distantPast
    private var lastDataAt = Date.distantPast
    private var stillSince: Date?

    public init() {}

    // MARK: Derived state for the UI

    /// The belt is moving although the phase says paused or stopped.
    public var slowingDown: Bool { (phase == .paused || phase == .stopped) && speed > 0 }
    public var isStopping: Bool { intent == .stop }
    /// A start or resume is on its way (countdown, or waiting for the belt to stand still).
    public var isStarting: Bool {
        if phase == .starting { return true }
        if case .run = intent, phase != .running { return true }
        return false
    }
    public var waitsForStandstill: Bool {
        if case .run = intent, slowingDown { return true }
        return false
    }

    // MARK: Inputs

    public mutating func user(_ i: Intent) {
        // Speed changes on a belt that is not moving only update the target, they never start it.
        intent = i
        attempts = 0
        waitUntil = nil
        failure = nil
    }

    public mutating func observe(speed s: Double, elapsed: Int?, now: Date = Date()) {
        speed = s
        lastDataAt = now
        if s > 0 { stillSince = nil } else if stillSince == nil { stillSince = now }
        let e = elapsed ?? lastElapsed
        defer { lastElapsed = e }
        if phase == .unknown {
            set(s > 0 ? .running : .stopped, now)
        } else if (phase == .stopped || phase == .paused), s > 0, e > lastElapsed, intent == .none,
                  now.timeIntervalSince(phaseChangedAt) > 3 {
            set(.running, now) // started from the treadmill itself
        }
    }

    public mutating func observe(status: MachineStatus, now: Date = Date()) {
        switch status {
        case .startedOrResumed:
            set(.running, now)
            startAcceptedAt = nil
            acceptedSpeed = nil // resumes at its own speed; a run intent sends ours next
        case .pausedByUser:
            set(.paused, now)
            if intent == .pause { intent = .none }
        case .stoppedByUser, .stoppedBySafetyKey, .reset:
            set(.stopped, now)
            acceptedSpeed = nil
            if intent == .stop || intent == .pause { intent = .none }
        case .targetSpeedChanged(let v):
            if v > 0 { acceptedSpeed = v }
        default:
            break
        }
        waitUntil = nil // the state changed: worth trying again at once
    }

    /// Result of a command this controller asked for. `result` nil = the treadmill did not answer.
    public mutating func observe(response cmd: ControlCommand, result: ControlResponse.Result?, now: Date = Date()) {
        guard result == .success else {
            waitUntil = now.addingTimeInterval(retryDelay)
            return
        }
        switch cmd {
        case .startOrResume:
            set(.starting, now)
            startAcceptedAt = now
        case .pause:
            if phase == .running || phase == .starting { set(.paused, now) }
            if intent == .pause { intent = .none }
        case .stop:
            set(.stopped, now)
            acceptedSpeed = nil
            if intent == .stop { intent = .none }
        case .setSpeed(let v):
            acceptedSpeed = v
            if intent == .run(v) { intent = .none }
        default:
            break
        }
    }

    /// Link lost: nothing is known about the belt any more; a pending intent is dropped.
    public mutating func linkReset() {
        self = BeltController()
    }

    // MARK: Output

    /// The next command, or nil to wait. Call when the control queue is idle.
    public mutating func next(now: Date = Date()) -> ControlCommand? {
        if phase == .starting, let t = startAcceptedAt, now.timeIntervalSince(t) > countdownTimeout {
            // No "started" status: believe the data stream.
            set(speed > 0 ? .running : .stopped, now)
            startAcceptedAt = nil
        }
        if let w = waitUntil, now < w { return nil }
        // No data for 3 s: treat the belt as standing (the treadmill keeps sending while it moves).
        let stale = now.timeIntervalSince(lastDataAt) >= 3
        let settled = stale || (stillSince.map { now.timeIntervalSince($0) >= settleTime } ?? false)
        let moving = !settled

        switch intent {
        case .none:
            return nil
        case .stop:
            switch phase {
            case .running, .starting: return issue(.pause, now)
            case .paused, .unknown: return moving ? nil : issue(.stop, now) // refused while moving
            case .stopped:
                intent = .none
                return nil
            }
        case .pause:
            switch phase {
            case .running, .starting: return issue(.pause, now)
            default:
                intent = .none
                return nil
            }
        case .run(let v):
            switch phase {
            case .running:
                if let a = acceptedSpeed, abs(a - v) < 0.05 {
                    intent = .none
                    return nil
                }
                return issue(.setSpeed(v), now)
            case .starting:
                return nil // countdown; the speed follows "started"
            case .paused, .stopped, .unknown:
                return moving ? nil : issue(.startOrResume, now) // refused while moving
            }
        }
    }

    private mutating func issue(_ cmd: ControlCommand, _ now: Date) -> ControlCommand? {
        attempts += 1
        guard attempts <= maxAttempts else {
            failure = "The treadmill kept refusing \(cmd)"
            intent = .none
            return nil
        }
        // Until the answer arrives the queue is busy, so next() is not called again.
        return cmd
    }

    private mutating func set(_ p: Phase, _ now: Date) {
        if p != phase { phaseChangedAt = now }
        phase = p
    }
}
