import Foundation

/// One step of an interval program.
public struct ProgramSegment: Codable, Equatable, Hashable, Sendable {
    public var seconds: Int
    /// km/h
    public var speed: Double

    public init(seconds: Int, speed: Double) {
        self.seconds = seconds; self.speed = speed
    }

    public init(minutes: Double, speed: Double) {
        self.init(seconds: Int(minutes * 60), speed: speed)
    }
}

/// Speed program run by the app. The X218 has no program mode of its own, so the app changes the speed at
/// every segment boundary.
/// Program time is the treadmill's elapsed time, so a pause also pauses the program.
public struct WorkoutProgram: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var segments: [ProgramSegment]
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String, segments: [ProgramSegment], builtIn: Bool = false) {
        self.id = id; self.name = name; self.segments = segments; self.builtIn = builtIn
    }

    public var totalSeconds: Int { segments.reduce(0) { $0 + $1.seconds } }
    public var maxSpeed: Double { segments.map(\.speed).max() ?? 0 }

    /// Distance in metres if every segment runs at its speed.
    public var plannedDistance: Int {
        Int(segments.reduce(0.0) { $0 + Double($1.seconds) * $1.speed / 3.6 })
    }

    /// Segment index and seconds left in it at program time `t`; nil once the program is over.
    public func position(at t: Int) -> (index: Int, remaining: Int)? {
        var start = 0
        for (i, s) in segments.enumerated() {
            if t < start + s.seconds { return (i, start + s.seconds - t) }
            start += s.seconds
        }
        return nil
    }

    /// Same program with every speed limited to `limit` (the app's safety limit).
    public func capped(at limit: Double) -> WorkoutProgram {
        var p = self
        p.segments = segments.map { ProgramSegment(seconds: $0.seconds, speed: min($0.speed, limit)) }
        return p
    }

    /// Walking programs for a treadmill desk; all speeds within the default 6 km/h limit.
    public static let templates: [WorkoutProgram] = {
        func t(_ name: String, _ uuid: String, _ segs: [ProgramSegment]) -> WorkoutProgram {
            WorkoutProgram(id: UUID(uuidString: uuid)!, name: name, segments: segs, builtIn: true)
        }
        let intervals = (0..<6).flatMap { _ in [ProgramSegment(minutes: 2, speed: 5.0), ProgramSegment(minutes: 2, speed: 3.5)] }
        return [
            t("Easy walk, 20 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0001",
              [.init(minutes: 3, speed: 2.5), .init(minutes: 14, speed: 3.5), .init(minutes: 3, speed: 2.5)]),
            t("Walking intervals, 30 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0002",
              [.init(minutes: 5, speed: 3.0)] + intervals + [.init(minutes: 1, speed: 3.0)]),
            t("Power walk, 30 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0003",
              [.init(minutes: 5, speed: 3.5), .init(minutes: 20, speed: 5.5), .init(minutes: 5, speed: 3.5)]),
            t("Fat burn, 45 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0004",
              [.init(minutes: 5, speed: 3.0), .init(minutes: 35, speed: 4.5), .init(minutes: 5, speed: 3.0)]),
            t("Pyramid, 32 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0005",
              [3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 5.0, 4.5, 4.0, 3.5, 3.0].enumerated().map {
                  ProgramSegment(minutes: $0.offset == 5 ? 4 : 2.8, speed: $0.element)
              }),
            t("Long walk, 60 min", "6B1C2E36-2B0D-4F45-9F12-1C7E3A0A0006",
              [.init(minutes: 5, speed: 3.0), .init(minutes: 50, speed: 4.0), .init(minutes: 5, speed: 3.0)]),
        ]
    }()
}

/// JSON list of the user's own programs next to the workout history.
public final class ProgramStore: @unchecked Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        WorkoutStore.defaultURL().deletingLastPathComponent().appendingPathComponent("programs.json")
    }

    public func load() -> [WorkoutProgram] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WorkoutProgram].self, from: d)) ?? []
    }

    public func save(_ programs: [WorkoutProgram]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(programs).write(to: url, options: .atomic)
    }
}
