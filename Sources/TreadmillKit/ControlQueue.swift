import Foundation

/// Serialises FTMS Control Point writes: one command in flight at a time, the next one only after the
/// treadmill answered (or after `timeout`).
///
/// Rules (fast clicking produced overlapping writes, and after a Stop the treadmill resets and answers every
/// later command with "not permitted"):
/// - speed changes collapse into the newest one, so fast clicks end at the speed the user picked;
/// - Stop drops everything pending and goes first; Pause drops pending speed changes;
/// - without control (start, or after the treadmill reset) Request Control goes out first;
/// - a command answered "not permitted" may mean control was lost (after a reset), so the next command
///   asks for control first. Whether to retry is up to BeltController: the same answer also means
///   "not in this phase" (start while the belt still moves).
public struct ControlQueue: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ignored
        case done(ControlCommand)
        case failed(ControlCommand, ControlResponse)
    }

    public private(set) var pending: [ControlCommand] = []
    public private(set) var inFlight: ControlCommand?
    public private(set) var sentAt: Date?
    public var hasControl = false
    public var timeout: TimeInterval = 1.5

    public init() {}

    public var isIdle: Bool { pending.isEmpty && inFlight == nil }

    public var pendingSpeed: Double? {
        for c in ([inFlight].compactMap { $0 } + pending).reversed() {
            if case .setSpeed(let v) = c { return v }
        }
        return nil
    }

    public mutating func enqueue(_ cmd: ControlCommand) {
        switch cmd {
        case .stop:
            pending = [.stop]
        case .pause:
            pending.removeAll { if case .setSpeed = $0 { return true } else { return $0 == .pause } }
            pending.append(.pause)
        case .setSpeed:
            pending.removeAll { if case .setSpeed = $0 { return true } else { return false } }
            pending.append(cmd)
        default:
            if pending.last != cmd { pending.append(cmd) }
        }
    }

    /// The in-flight command the treadmill did not answer within `timeout`, freeing the queue.
    public mutating func expire(now: Date = Date()) -> ControlCommand? {
        guard let f = inFlight, let t = sentAt, now.timeIntervalSince(t) >= timeout else { return nil }
        inFlight = nil
        sentAt = nil
        return f
    }

    /// The command to write now, or nil. Call after enqueue, after every response, and on a timer.
    public mutating func next(now: Date = Date()) -> ControlCommand? {
        _ = expire(now: now)
        guard inFlight == nil else { return nil }
        guard !pending.isEmpty else { return nil }
        let cmd = hasControl ? pending.removeFirst() : .requestControl
        inFlight = cmd
        sentAt = now
        return cmd
    }

    public mutating func handle(_ r: ControlResponse) -> Outcome {
        guard let f = inFlight, f.opcode == r.requestOpcode else { return .ignored }
        inFlight = nil
        sentAt = nil

        if f == .requestControl {
            hasControl = r.result == .success
            if !hasControl { pending.removeAll() }
            return hasControl ? .done(f) : .failed(f, r)
        }
        if r.result == .notPermitted { hasControl = false }
        return r.result == .success ? .done(f) : .failed(f, r)
    }

    /// The treadmill reset (after Stop) and forgot who has control. The command in flight stays: its
    /// answer still comes (a Start sent just before the reset is accepted).
    public mutating func controlLost() {
        hasControl = false
    }

    /// Link dropped: nothing in flight, control must be asked for again.
    public mutating func reset(keepPending: Bool = false) {
        if !keepPending { pending.removeAll() }
        inFlight = nil
        sentAt = nil
        hasControl = false
    }
}
