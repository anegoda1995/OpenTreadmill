import Foundation
import Testing
@testable import TreadmillKit

private func sample(_ speed: Double, _ elapsed: Int, _ dist: Int, kcal: Int = 0, steps: Int = 0) -> TreadmillData {
    var t = TreadmillData()
    t.speed = speed; t.elapsed = elapsed; t.distance = dist; t.calories = kcal; t.steps = steps
    return t
}

@Suite struct WorkoutRecorderTests {
    @Test func sessionClosesWhenCountersReset() throws {
        var r = WorkoutRecorder()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for s in 1...30 { #expect(r.ingest(sample(3.0, s, s * 1, kcal: s / 10, steps: s * 2), deviceName: "Treadmill", now: t0 + Double(s)) == nil) }
        let closed = r.ingest(sample(0, 0, 0), deviceName: "Treadmill", now: t0 + 40)
        let rec = try #require(closed)
        #expect(rec.duration == 30)
        #expect(rec.distance == 30)
        #expect(rec.steps == 60)
        #expect(rec.speedSamples.count == 30)
        #expect(rec.start == t0)
        #expect(r.current == nil)
    }

    @Test func pauseKeepsOneSession() {
        var r = WorkoutRecorder()
        for s in 1...20 { _ = r.ingest(sample(3, s, s), deviceName: "Treadmill") }
        for _ in 0..<15 { #expect(r.ingest(sample(0, 20, 20), deviceName: "Treadmill") == nil) } // paused
        for s in 21...25 { _ = r.ingest(sample(3, s, s), deviceName: "Treadmill") }
        let rec = r.finish(deviceName: "Treadmill")
        #expect(rec?.duration == 25)
        #expect(rec?.speedSamples.count == 25)
    }

    @Test func shortSessionIsDropped() {
        var r = WorkoutRecorder()
        for s in 1...5 { _ = r.ingest(sample(2, s, s), deviceName: "Treadmill") }
        #expect(r.finish(deviceName: "Treadmill") == nil)
    }

    @Test func midSessionConnectStartsFromTreadmillTotals() throws {
        // The Mac connects while the belt has already run 721 s, like the phone did in the capture.
        var r = WorkoutRecorder()
        let now = Date(timeIntervalSince1970: 2_000_000)
        _ = r.ingest(sample(3, 721, 570), deviceName: "Treadmill", now: now)
        #expect(r.current?.start == now - 721)
        let finished = r.finish(deviceName: "Treadmill", now: now)
        let rec = try #require(finished)
        #expect(rec.duration == 721)
    }

    @Test func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkoutStore(url: dir.appendingPathComponent("w.json"))
        #expect(store.load().isEmpty)
        let rec = WorkoutRecord(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200),
                                duration: 100, distance: 250, calories: 12, steps: 300, maxSpeed: 4,
                                deviceName: "KS-NG-X18F3", speedSamples: [3, 4])
        try store.save([rec])
        #expect(store.load() == [rec])
        #expect(abs(rec.averageSpeed - 9.0) < 0.001)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func reconnectMergesIntoOneRecord() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let part = WorkoutRecord(start: t0, end: t0 + 600, duration: 600, distance: 500, calories: 30, steps: 900,
                                 maxSpeed: 3.5, deviceName: "Treadmill", speedSamples: Array(repeating: 3.0, count: 600))
        let whole = WorkoutRecord(start: t0 + 2, end: t0 + 1200, duration: 1200, distance: 1100, calories: 70, steps: 1900,
                                  maxSpeed: 4.0, deviceName: "Treadmill", speedSamples: Array(repeating: 4.0, count: 1200))
        var list: [WorkoutRecord] = []
        list.addMerging(part)
        list.addMerging(whole)
        #expect(list.count == 1)
        #expect(list[0].id == part.id)
        #expect(list[0].duration == 1200)
        #expect(list[0].start == t0)
        #expect(list[0].speedSamples.count == 1200)
        #expect(list[0].speedSamples.first == 3.0)
        #expect(list[0].speedSamples.last == 4.0)
        list.addMerging(part) // an older, shorter copy never replaces the longer one
        #expect(list[0].duration == 1200)
        let other = WorkoutRecord(start: t0 + 5000, end: t0 + 5600, duration: 600, distance: 1, calories: 1, steps: 1,
                                  maxSpeed: 1, deviceName: "Treadmill", speedSamples: [])
        list.addMerging(other)
        #expect(list.count == 2)
    }
}

@Suite struct WorkoutMetricsTests {
    @Test func metricsLikeThePhone() {
        // 1.96 km, 39:57, 3595 steps -> pace 20'22", 89 spm, stride ~54 cm.
        let r = WorkoutRecord(start: Date(), end: Date(), duration: 2397, distance: 1960, calories: 137, steps: 3595,
                              maxSpeed: 3.6, deviceName: "Treadmill", speedSamples: [])
        #expect(abs((r.pace ?? 0) - 1222.9) < 1) // 20'22"
        #expect(abs(r.cadence - 90) < 1.5)
        #expect(abs((r.stride ?? 0) - 54.5) < 0.5)
    }

    @Test func cadenceSeries() {
        var r = WorkoutRecord(start: Date(), end: Date(), duration: 120, distance: 100, calories: 1, steps: 180,
                              maxSpeed: 3, deviceName: "Treadmill", speedSamples: [])
        r.stepSamples = (0..<120).map { $0 * 3 / 2 } // 1.5 steps/s = 90 spm
        let s = r.cadenceSeries(bucket: 30)
        #expect(s.count == 3)
        #expect(abs(s[0].spm - 90) < 2)
    }

    @Test func runIdSetsExactStartAndMerges() throws {
        var rec = WorkoutRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 900)
        var t = TreadmillData(); t.speed = 4; t.elapsed = 880; t.distance = 900; t.steps = 1400
        _ = rec.ingest(t, deviceName: "Treadmill", now: now)
        rec.setRunId(1_800_000_000, now: now)
        #expect(rec.current?.start == Date(timeIntervalSince1970: 1_800_000_000))
        let finished = rec.finish(deviceName: "Treadmill", now: now)
        let a = try #require(finished)
        #expect(a.runId == 1_800_000_000)
        var list = [a]
        var b = a; b.id = UUID(); b.duration = 1000; b.start = a.start.addingTimeInterval(60) // pauses shifted start
        list.addMerging(b)
        #expect(list.count == 1) // same runId wins over a start difference
        #expect(list[0].duration == 1000)
    }

    @Test func activitySummary() {
        let cal = Calendar(identifier: .gregorian)
        let d1 = Date(timeIntervalSince1970: 1_800_000_000)
        let r1 = WorkoutRecord(start: d1, end: d1, duration: 600, distance: 1000, calories: 50, steps: 1500,
                               maxSpeed: 3, deviceName: "Treadmill", speedSamples: [])
        var r2 = r1; r2.id = UUID(); r2.start = d1.addingTimeInterval(3600)
        var r3 = r1; r3.id = UUID(); r3.start = d1.addingTimeInterval(86_400 * 2)
        let s = ActivitySummary([r1, r2, r3], calendar: cal)
        #expect(s.workouts == 3 && s.activeDays == 2 && s.distance == 3000 && s.duration == 1800)
        #expect(ActivitySummary.filter([r1, r2, r3], sameDayAs: d1, calendar: cal).count == 2)
        let days = ActivitySummary.daily([r1, r2, r3], days: 7, until: r3.start, calendar: cal)
        #expect(days.count == 7)
        #expect(days.last?.summary.workouts == 1)
    }
}
