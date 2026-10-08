import Foundation

/// KingSmith's own GATT protocol, next to FTMS ("supplement" service, used by the X218 for settings and run ids).
///
/// Frame: `cmd sub len payload… checksum`, checksum = sum of all previous bytes mod 256.
/// Replies set bit 7 of `sub`. Integers are little endian. Builders below reproduce the exact byte
/// lists the treadmill expects; the unit tests hold frames recorded from a real X218.
public enum KingsmithProtocol {
    // The service UUID was not captured; the app finds these two characteristics in any service.
    public static let notify = "24E2521C-F63B-48ED-85BE-C5330B00FDF7"
    public static let write = "24E2521C-F63B-48ED-85BE-C5330D00FDF7"

    public static let cmdSystem: UInt8 = 0x71
    public static let cmdProperty: UInt8 = 0x72
    public static let cmdEvent: UInt8 = 0x73
    public static let cmdAction: UInt8 = 0x75
    public static let cmdHeartRate: UInt8 = 0x76

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) })
    }

    /// Appends the checksum.
    public static func wrap(_ bytes: [UInt8]) -> Data {
        Data(bytes + [checksum(bytes)])
    }

    /// Opening handshake: the last 4 characters of the advertised name read as a
    /// little-endian u32, plus a random byte that is also sent in clear.
    public static func unlock(deviceName: String, random: UInt8 = UInt8.random(in: 0..<255)) -> Data {
        let tail = Array(deviceName.utf16.suffix(4)).map { UInt8(truncatingIfNeeded: $0) }
        var key: UInt32 = 0
        for (i, b) in tail.enumerated() { key |= UInt32(b) << (8 * UInt32(i)) }
        let v = key &+ UInt32(random)
        return wrap([cmdSystem, 0x00, 0x05, random] + .le32(v))
    }

    /// System info: current unix time and the account id the treadmill tags its stored runs with.
    public static func systemInfo(unixTime: UInt32, userId: UInt32) -> Data {
        wrap([cmdSystem, 0x01, 0x08] + .le32(unixTime) + .le32(userId))
    }

    /// Reads every property.
    public static func readAllProperties() -> Data { wrap([cmdProperty, 0x00, 0x00, 0x00]) }

    /// Lists the supported actions.
    public static func actionList() -> Data { wrap([cmdAction, 0x00, 0x00]) }
}

// MARK: - Incoming frames

public enum KingsmithMessage: Equatable, Sendable {
    case unlockOK
    case unlockFailed(UInt8)
    case systemInfo(protocolVersion: UInt32, abilities: UInt32)
    case properties([UInt16: UInt16])
    /// "结算事件" settlement: a finished run stored on the treadmill.
    case workoutEvent(number: UInt8, runId: UInt32, userId: UInt32)
    case actions([UInt8])
    case unknown(cmd: UInt8, sub: UInt8, payload: [UInt8])

    /// Parses one frame. Returns nil when the length or checksum is wrong.
    public static func parse(_ data: Data) -> KingsmithMessage? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let len = Int(b[2])
        guard b.count >= 3 + len + 1 else { return nil }
        let frame = b[0..<(3 + len)]
        guard KingsmithProtocol.checksum(frame) == b[3 + len] else { return nil }
        let cmd = b[0], sub = b[1]
        let payload = Array(b[3..<(3 + len)])
        var r = ByteReader(payload)

        switch (cmd, sub) {
        case (KingsmithProtocol.cmdSystem, 0x80):
            return len == 0 ? .unlockOK : .unlockFailed(payload.first ?? 0)
        case (KingsmithProtocol.cmdSystem, 0x81):
            guard let v = r.u32(), let a = r.u32() else { return nil }
            return .systemInfo(protocolVersion: v, abilities: a)
        case (KingsmithProtocol.cmdProperty, 0x80):
            var props: [UInt16: UInt16] = [:]
            while r.remaining >= 4, let id = r.u16(), let value = r.u16() { props[id] = value }
            return .properties(props)
        case (KingsmithProtocol.cmdEvent, 0x50):
            guard let n = r.u8(), let run = r.u32(), let uid = r.u32() else { return nil }
            return .workoutEvent(number: n, runId: run, userId: uid)
        case (KingsmithProtocol.cmdAction, 0x80):
            return .actions(payload)
        default:
            return .unknown(cmd: cmd, sub: sub, payload: payload)
        }
    }
}

// MARK: - Properties

/// Property ids seen in the X218 reply.
public enum KingsmithProperty: UInt16, CaseIterable, Sendable {
    case units = 1
    case autoStop = 2
    case motorVersion = 4
    case errorCode = 5
    case childLock = 6
    case maxSpeed = 7
    case switches = 8
    case foldLock = 9
    case modeStatus = 10
    case colour = 13
}

public struct DeviceProperties: Equatable, Sendable {
    public var raw: [UInt16: UInt16]

    public init(raw: [UInt16: UInt16]) { self.raw = raw }

    func value(_ p: KingsmithProperty) -> UInt16? { raw[p.rawValue] }

    public var metric: Bool { (value(.units) ?? 0) == 0 }
    public var errorCode: Int { Int(value(.errorCode) ?? 0) }
    public var childLockOn: Bool { (value(.childLock) ?? 0) != 0 }
    /// km/h. Property 7: low 10 bits in 0.1 km/h, bits 15/14/13 = can set max / walk max / run max.
    public var maxSpeed: Double? { value(.maxSpeed).map { Double($0 & 0x03FF) / 10 } }

    /// Property 2: bit 15 auto stop on, bit 14 time can be set, bit 13 time enabled, low bits minutes.
    /// Seen 0x403C: "autoStop off, couldSetTime true, setTimeEnable false, time 60".
    public var autoStopEnabled: Bool { (value(.autoStop) ?? 0) & 0x8000 != 0 }
    public var autoStopTimeSettable: Bool { (value(.autoStop) ?? 0) & 0x4000 != 0 }
    public var autoStopTimeEnabled: Bool { (value(.autoStop) ?? 0) & 0x2000 != 0 }
    public var autoStopMinutes: Int { Int((value(.autoStop) ?? 0) & 0x1FFF) }

    /// Property 8 bit pairs (support, on): sound, light, fold check, handrail. Seen 0x3F. The order
    /// is the usual support/on pairing; only "all six set" has been observed so far.
    private func bit(_ n: Int) -> Bool { (value(.switches) ?? 0) & (1 << n) != 0 }
    public var soundSupported: Bool { bit(0) }
    public var soundOn: Bool { bit(1) }
    public var lightSupported: Bool { bit(2) }
    public var lightOn: Bool { bit(3) }
    public var foldCheckSupported: Bool { bit(4) }
    public var foldCheckOn: Bool { bit(5) }

    public var foldLockSupported: Bool { (value(.foldLock) ?? 0) & 0x01 != 0 }
    public var foldLockOn: Bool { (value(.foldLock) ?? 0) & 0x02 != 0 }
}

extension KingsmithProtocol {
    /// Writes properties: `72 01 <3n> (id u8, value u16)*`.
    public static func setProperties(_ items: [(id: UInt16, value: UInt16)]) -> Data {
        var b: [UInt8] = [cmdProperty, 0x01, UInt8(truncatingIfNeeded: items.count * 3)]
        for i in items { b += [UInt8(truncatingIfNeeded: i.id)] + .le16(i.value) }
        return wrap(b)
    }

    /// Buzzer: property 8 = 3 (on) or 1 (off). Bit 0 ("supported") tells the
    /// treadmill which switch the write is about, so the other switches in property 8 stay as they are.
    public static func setSound(_ on: Bool) -> Data { setProperties([(8, on ? 0x03 : 0x01)]) }

    /// Marquee light: property 8 = 0x0C (on) or 0x04 (off).
    public static func setLight(_ on: Bool) -> Data { setProperties([(8, on ? 0x0C : 0x04)]) }
}

/// Workout goal kept by the app: the X218 reports no target support in 2ACC (Fitness Machine Feature, target
/// settings field = speed only), so the
/// app watches the counters and stops the belt when the goal is reached.
public struct WorkoutGoal: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case time, distance, calories }

    public var kind: Kind
    /// seconds, metres or kcal
    public var value: Int
    /// Counter value when the goal was set during a run (0 when set before the start).
    public var baseline: Int = 0

    public init(kind: Kind, value: Int, baseline: Int = 0) {
        self.kind = kind; self.value = value; self.baseline = baseline
    }

    public func counter(_ t: TreadmillData) -> Int {
        switch kind {
        case .time: t.elapsed ?? 0
        case .distance: t.distance ?? 0
        case .calories: t.calories ?? 0
        }
    }

    public func done(_ t: TreadmillData) -> Int { max(0, counter(t) - baseline) }

    public func progress(_ t: TreadmillData) -> Double {
        value > 0 ? min(1, Double(done(t)) / Double(value)) : 0
    }

    public func reached(_ t: TreadmillData) -> Bool { value > 0 && done(t) >= value }
}

extension KingsmithProtocol {
    /// Child lock: property 6 = 3 (on) or 0 (off).
    public static func setChildLock(_ on: Bool) -> Data { setProperties([(6, on ? 0x03 : 0x00)]) }

    /// Idle shutdown ("auto stop"): property 2 = 0xE000 | minutes when on with a
    /// time (bits 15/14/13: on, time settable, time set), 0 when off.
    public static func setIdleShutdown(minutes: Int?) -> Data {
        guard let m = minutes, m > 0 else { return setProperties([(2, 0)]) }
        return setProperties([(2, 0xE000 | UInt16(min(m, 0x1FFF)))])
    }
}

/// Machine modes in property 10 (bits 5 and up). Bit 9 says the treadmill can sleep.
public enum KingsmithMode: UInt16, Sendable {
    case manual = 0, auto = 1, standby = 2, course = 3, customProgram = 4
}

extension KingsmithProtocol {
    /// Mode change: property 10 = mode << 5.
    public static func setMode(_ mode: KingsmithMode) -> Data { setProperties([(10, mode.rawValue << 5)]) }

    /// Sleep: standby mode. The treadmill switches off and drops the Bluetooth link; its own button or the remote
    /// wakes it up.
    public static func sleep() -> Data { setMode(.standby) }
}

extension DeviceProperties {
    public var sleepSupported: Bool { (raw[KingsmithProperty.modeStatus.rawValue] ?? 0) & 0x0200 != 0 }

    /// Current mode; standby means the treadmill is going to sleep.
    public var mode: KingsmithMode? {
        raw[KingsmithProperty.modeStatus.rawValue].flatMap { KingsmithMode(rawValue: ($0 >> 5) & 0x0F) }
    }
}
