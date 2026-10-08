import Foundation

/// Bluetooth SIG Fitness Machine Service (FTMS 1.0) as used by the KingSmith X218 (KS-NG-X18F3).
/// The formats follow the FTMS 1.0 specification and were checked against frames recorded from a real X218.
public enum FTMS {
    public static let service = "1826"
    public static let feature = "2ACC"
    public static let treadmillData = "2ACD"
    public static let trainingStatus = "2AD3"
    public static let supportedSpeedRange = "2AD4"
    public static let supportedInclinationRange = "2AD5"
    public static let supportedHeartRateRange = "2AD7"
    public static let controlPoint = "2AD9"
    public static let machineStatus = "2ADA"

    public static let deviceInfoService = "180A"
    public static let firmwareRevision = "2A26"
    public static let softwareRevision = "2A28"
    public static let manufacturerName = "2A29"
}

// MARK: - Treadmill Data (0x2ACD)

/// One 2ACD notification. Units are converted to plain SI-ish values the UI can show directly.
public struct TreadmillData: Equatable, Sendable {
    /// km/h
    public var speed: Double = 0
    public var averageSpeed: Double?
    /// metres
    public var distance: Int?
    /// percent
    public var inclination: Double?
    public var calories: Int?
    public var caloriesPerHour: Int?
    public var heartRate: Int?
    /// seconds
    public var elapsed: Int?
    public var remaining: Int?
    /// KingSmith extension in flag bit 13 (not part of FTMS 1.0).
    public var steps: Int?

    public init() {}

    /// Parses a Treadmill Data value. Returns nil only when the mandatory part is missing.
    public static func parse(_ data: Data) -> TreadmillData? {
        var r = ByteReader(data)
        guard let flags = r.u16() else { return nil }
        var t = TreadmillData()
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }

        // Bit 0 is "More Data": when it is 0 the instantaneous speed is present.
        if !has(0) {
            guard let v = r.u16() else { return nil }
            t.speed = Double(v) / 100
        }
        if has(1) { t.averageSpeed = r.u16().map { Double($0) / 100 } }
        if has(2) { t.distance = r.u24().map(Int.init) }
        if has(3) {
            t.inclination = r.s16().map { Double($0) / 10 }
            _ = r.s16() // ramp angle setting
        }
        if has(4) { _ = r.u16(); _ = r.u16() } // elevation gain +/-
        if has(5) { _ = r.u8() } // instantaneous pace
        if has(6) { _ = r.u8() } // average pace
        if has(7) {
            t.calories = r.u16().map(Int.init)
            t.caloriesPerHour = r.u16().map(Int.init)
            _ = r.u8() // per minute
        }
        if has(8) { t.heartRate = r.u8().map(Int.init) }
        if has(9) { _ = r.u8() } // metabolic equivalent
        if has(10) { t.elapsed = r.u16().map(Int.init) }
        if has(11) { t.remaining = r.u16().map(Int.init) }
        if has(12) { _ = r.s16(); _ = r.s16() } // force on belt, power
        if has(13) {
            // The X218 sends steps as 3 bytes; fall back to 2 if a firmware sends fewer.
            if r.remaining >= 3 { t.steps = r.u24().map(Int.init) } else { t.steps = r.u16().map(Int.init) }
        }
        return t
    }
}

// MARK: - Feature, ranges, statuses

public struct SpeedRange: Equatable, Sendable {
    /// km/h
    public var min: Double
    public var max: Double
    public var step: Double

    public init(min: Double, max: Double, step: Double) {
        self.min = min; self.max = max; self.step = step
    }

    /// Range used before 2AD4 has been read: the X218 values from the log.
    public static let x218 = SpeedRange(min: 1.0, max: 18.0, step: 0.1)

    public static func parse(_ data: Data) -> SpeedRange? {
        var r = ByteReader(data)
        guard let lo = r.u16(), let hi = r.u16(), let inc = r.u16(), hi > lo, inc > 0 else { return nil }
        return SpeedRange(min: Double(lo) / 100, max: Double(hi) / 100, step: Double(inc) / 100)
    }

    /// Clamps and snaps a requested speed to what the machine accepts.
    public func clamp(_ kmh: Double) -> Double {
        let snapped = (kmh / step).rounded() * step
        return Swift.min(max, Swift.max(min, (snapped * 100).rounded() / 100))
    }
}

public struct MachineFeature: Equatable, Sendable {
    public var raw: UInt32
    public var targets: UInt32
    public var heartRate: Bool { raw & (1 << 10) != 0 }
    public var inclination: Bool { raw & (1 << 3) != 0 }
    public var stepCount: Bool { raw & (1 << 6) != 0 }
    public var elapsedTime: Bool { raw & (1 << 12) != 0 }

    public static func parse(_ data: Data) -> MachineFeature? {
        var r = ByteReader(data)
        guard let f = r.u32() else { return nil }
        return MachineFeature(raw: f, targets: r.u32() ?? 0)
    }
}

/// 2AD3 Training Status.
public enum TrainingStatus: UInt8, Sendable {
    case other = 0x00, idle = 0x01, warmingUp = 0x02, lowIntensity = 0x03, highIntensity = 0x04
    case recovery = 0x05, isometric = 0x06, heartRateControl = 0x07, fitnessTest = 0x08
    case speedTooLow = 0x09, speedTooHigh = 0x0A, coolDown = 0x0B, wattControl = 0x0C
    case manualMode = 0x0D, preWorkout = 0x0E, postWorkout = 0x0F

    public static func parse(_ data: Data) -> TrainingStatus? {
        var r = ByteReader(data)
        guard r.u8() != nil, let s = r.u8() else { return nil }
        return TrainingStatus(rawValue: s)
    }
}

/// 2ADA Fitness Machine Status notifications.
public enum MachineStatus: Equatable, Sendable {
    case reset
    case stoppedByUser
    case pausedByUser
    case stoppedBySafetyKey
    case startedOrResumed
    case targetSpeedChanged(Double)
    case targetInclineChanged(Double)
    case controlPermissionLost
    case other(UInt8)

    public static func parse(_ data: Data) -> MachineStatus? {
        var r = ByteReader(data)
        guard let op = r.u8() else { return nil }
        switch op {
        case 0x01: return .reset
        case 0x02: return r.u8() == 0x02 ? .pausedByUser : .stoppedByUser
        case 0x03: return .stoppedBySafetyKey
        case 0x04: return .startedOrResumed
        case 0x05: return .targetSpeedChanged(Double(r.u16() ?? 0) / 100)
        case 0x06: return .targetInclineChanged(Double(r.s16() ?? 0) / 10)
        case 0xFF: return .controlPermissionLost
        default: return .other(op)
        }
    }
}

// MARK: - Control Point (0x2AD9)

public enum ControlCommand: Equatable, Sendable {
    case requestControl
    case reset
    /// km/h, sent in 0.01 km/h units
    case setSpeed(Double)
    /// percent, sent in 0.1 % units
    case setInclination(Double)
    case startOrResume
    case stop
    case pause
    /// kcal
    case targetCalories(Int)
    /// metres
    case targetDistance(Int)
    /// seconds
    case targetTime(Int)

    public var opcode: UInt8 {
        switch self {
        case .requestControl: 0x00
        case .reset: 0x01
        case .setSpeed: 0x02
        case .setInclination: 0x03
        case .startOrResume: 0x07
        case .stop, .pause: 0x08
        case .targetCalories: 0x09
        case .targetDistance: 0x0C
        case .targetTime: 0x0D
        }
    }

    /// Control Point frames as the X218 accepts them.
    public var bytes: [UInt8] {
        switch self {
        case .requestControl, .reset, .startOrResume:
            return [opcode]
        case .setSpeed(let kmh):
            return [opcode] + .le16(UInt16(clamping: Int((kmh * 100).rounded())))
        case .setInclination(let pct):
            return [opcode] + .le16(UInt16(bitPattern: Int16(clamping: Int((pct * 10).rounded()))))
        case .stop:
            return [opcode, 0x01]
        case .pause:
            return [opcode, 0x02]
        case .targetCalories(let kcal):
            return [opcode] + .le16(UInt16(clamping: kcal))
        case .targetDistance(let m):
            let v = UInt32(clamping: m)
            return [opcode, UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)]
        case .targetTime(let s):
            return [opcode] + .le16(UInt16(clamping: s))
        }
    }
}

public struct ControlResponse: Equatable, Sendable {
    public enum Result: UInt8, Sendable {
        case success = 0x01, notSupported = 0x02, invalidParameter = 0x03, failed = 0x04, notPermitted = 0x05
    }

    public var requestOpcode: UInt8
    public var result: Result?
    public var rawResult: UInt8

    /// Parses `80 <request opcode> <result> ...`.
    public static func parse(_ data: Data) -> ControlResponse? {
        var r = ByteReader(data)
        guard r.u8() == 0x80, let op = r.u8(), let res = r.u8() else { return nil }
        return ControlResponse(requestOpcode: op, result: Result(rawValue: res), rawResult: res)
    }
}
