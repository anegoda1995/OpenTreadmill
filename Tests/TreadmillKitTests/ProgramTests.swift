import Foundation
import Testing
@testable import TreadmillKit

@Suite struct ProgramTests {
    @Test func positionWalksThroughSegments() {
        let p = WorkoutProgram(name: "t", segments: [.init(seconds: 60, speed: 3), .init(seconds: 120, speed: 5)])
        #expect(p.totalSeconds == 180)
        #expect(p.position(at: 0)! == (0, 60))
        #expect(p.position(at: 59)! == (0, 1))
        #expect(p.position(at: 60)! == (1, 120))
        #expect(p.position(at: 179)! == (1, 1))
        #expect(p.position(at: 180) == nil)
    }

    @Test func templatesAreSaneForAWalkingDesk() {
        #expect(WorkoutProgram.templates.count >= 5)
        for t in WorkoutProgram.templates {
            #expect(t.builtIn)
            #expect(t.maxSpeed <= 6.0, "\(t.name) exceeds the default 6 km/h limit")
            #expect(t.segments.allSatisfy { $0.seconds > 0 && $0.speed >= 1.0 })
            // Names promise the length: within 2 minutes.
            if let m = t.name.split(separator: ",").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first,
               let minutes = Int(m) {
                #expect(abs(t.totalSeconds - minutes * 60) <= 120, "\(t.name): \(t.totalSeconds) s")
            }
        }
        #expect(Set(WorkoutProgram.templates.map(\.id)).count == WorkoutProgram.templates.count)
    }

    @Test func capKeepsTimingAndLimitsSpeed() {
        let p = WorkoutProgram(name: "t", segments: [.init(seconds: 60, speed: 8), .init(seconds: 60, speed: 3)]).capped(at: 6)
        #expect(p.segments.map(\.speed) == [6, 3])
        #expect(p.totalSeconds == 120)
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let s = ProgramStore(url: url)
        let p = WorkoutProgram(name: "Mine", segments: [.init(minutes: 1.5, speed: 3.3)])
        try s.save([p])
        #expect(s.load() == [p])
        try? FileManager.default.removeItem(at: url)
    }
}
