import Foundation

/// A finished treadmill session as the Mac app stores it.
public struct WorkoutRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    /// seconds of belt time reported by the treadmill (pauses excluded)
    public var duration: Int
    /// metres
    public var distance: Int
    public var calories: Int
    public var steps: Int
    /// km/h
    public var maxSpeed: Double
    public var deviceName: String
    /// One speed sample per elapsed second (km/h), for the chart.
    public var speedSamples: [Double]
    /// Cumulative steps per elapsed second, for the cadence chart. Nil in records from older versions.
    public var stepSamples: [Int]?
    /// The treadmill's own id of the run (unix time of its start), from the supplement event.
    public var runId: UInt32?
    /// Saved before the run ended (app quit, Bluetooth drop): the rest may still come.
    public var partial: Bool?

    public var averageSpeed: Double {
        duration > 0 ? Double(distance) / Double(duration) * 3.6 : 0
    }

    /// Seconds per km, nil without distance.
    public var pace: Double? { distance > 0 ? Double(duration) / (Double(distance) / 1000) : nil }

    /// Steps per minute over the whole run.
    public var cadence: Double { duration > 0 ? Double(steps) / (Double(duration) / 60) : 0 }

    /// Centimetres per step.
    public var stride: Double? { steps > 0 ? Double(distance) * 100 / Double(steps) : nil }

    /// Steps per minute in buckets of `bucket` seconds: (minute of the run, spm).
    public func cadenceSeries(bucket: Int = 30) -> [(minute: Double, spm: Double)] {
        guard let s = stepSamples, s.count > bucket else { return [] }
        var out: [(minute: Double, spm: Double)] = []
        for i in Swift.stride(from: bucket, to: s.count, by: bucket) {
            let delta = Double(Swift.max(0, s[i] - s[i - bucket]))
            out.append((minute: Double(i) / 60, spm: delta * 60 / Double(bucket)))
        }
        return out
    }

    public init(id: UUID = UUID(), start: Date, end: Date, duration: Int, distance: Int, calories: Int,
                steps: Int, maxSpeed: Double, deviceName: String, speedSamples: [Double],
                stepSamples: [Int]? = nil, runId: UInt32? = nil) {
        self.id = id; self.start = start; self.end = end; self.duration = duration
        self.distance = distance; self.calories = calories; self.steps = steps
        self.maxSpeed = maxSpeed; self.deviceName = deviceName; self.speedSamples = speedSamples
        self.stepSamples = stepSamples; self.runId = runId
    }

    func isSameRun(as other: WorkoutRecord) -> Bool {
        if let a = runId, let b = other.runId { return a == b }
        return deviceName == other.deviceName && abs(start.timeIntervalSince(other.start)) < 15
    }
}

extension Array where Element == WorkoutRecord {
    /// Adds a record, merging it with an earlier part of the same run. A reconnect mid-run (app relaunch,
    /// Bluetooth drop) saves the part before the drop, then the whole run again from the treadmill's
    /// counters: both start at the same moment, so a start within 15 s means "same run".
    public mutating func addMerging(_ rec: WorkoutRecord) {
        if let i = firstIndex(where: { $0.isSameRun(as: rec) }) {
            let old = self[i]
            guard rec.duration >= old.duration else {
                if self[i].runId == nil { self[i].runId = rec.runId }
                return
            }
            var merged = rec
            merged.id = old.id
            merged.start = old.start
            merged.maxSpeed = Swift.max(old.maxSpeed, rec.maxSpeed)
            // The part recorded before the drop has real samples; the reconnect filled them with one speed.
            if old.speedSamples.count <= rec.speedSamples.count {
                merged.speedSamples = old.speedSamples + rec.speedSamples.dropFirst(old.speedSamples.count)
            } else {
                merged.speedSamples = old.speedSamples
            }
            if let o = old.stepSamples, let n = rec.stepSamples, o.count <= n.count {
                merged.stepSamples = o + n.dropFirst(o.count)
            } else if rec.stepSamples == nil || (old.stepSamples?.count ?? 0) > (rec.stepSamples?.count ?? 0) {
                merged.stepSamples = old.stepSamples
            }
            if merged.deviceName.isEmpty { merged.deviceName = old.deviceName }
            merged.runId = rec.runId ?? old.runId
            merged.partial = rec.partial
            self[i] = merged
        } else {
            insert(rec, at: 0)
        }
    }
}

/// Turns the 1 Hz Treadmill Data stream into WorkoutRecords.
///
/// The treadmill counts elapsed time, distance, calories and steps itself, so the recorder keeps the
/// latest totals and closes the session when the counters reset, the belt reports a stop, or the
/// connection drops. Sessions under `minimumDuration` seconds are dropped as accidental starts.
public struct WorkoutRecorder: Sendable {
    public var minimumDuration = 10
    public private(set) var current: Session?

    public struct Session: Equatable, Sendable {
        public var start: Date
        public var last: TreadmillData
        public var maxSpeed: Double
        public var samples: [Double]
        public var stepSamples: [Int] = []
        public var runId: UInt32?
    }

    public init() {}

    /// The treadmill announced the id of the run in progress (unix time of its start): use it as the
    /// start time, it is exact even when the Mac connected in the middle of the run.
    public mutating func setRunId(_ id: UInt32, now: Date = Date()) {
        guard var s = current else { return }
        let start = Date(timeIntervalSince1970: TimeInterval(id))
        // Only an id that fits this run (started before now, within a day) is taken.
        guard start <= now, now.timeIntervalSince(start) < 86_400,
              abs(start.timeIntervalSince(s.start)) < 6 * 3600 else { return }
        s.runId = id
        s.start = start
        current = s
    }

    /// Feeds one sample. Returns a record when this sample shows that the previous session ended.
    public mutating func ingest(_ t: TreadmillData, deviceName: String, now: Date = Date()) -> WorkoutRecord? {
        let elapsed = t.elapsed ?? 0
        var finished: WorkoutRecord?

        if let s = current, elapsed < (s.last.elapsed ?? 0) {
            // Counters went backwards: the treadmill started a new run.
            finished = finish(deviceName: deviceName, now: now)
        }

        guard elapsed > 0 || t.speed > 0 else { return finished }

        if current == nil {
            current = Session(start: now.addingTimeInterval(-Double(elapsed)), last: t, maxSpeed: t.speed, samples: [])
        }
        current!.last = t
        current!.maxSpeed = max(current!.maxSpeed, t.speed)
        // One sample per elapsed second; pauses (elapsed not moving) add nothing.
        while current!.samples.count < elapsed { current!.samples.append(t.speed) }
        while current!.stepSamples.count < elapsed { current!.stepSamples.append(t.steps ?? 0) }
        return finished
    }

    /// Closes the running session (stop, disconnect, app quit). `partial`: the run may go on without us.
    public mutating func finish(deviceName: String, now: Date = Date(), partial: Bool = false) -> WorkoutRecord? {
        guard let s = current else { return nil }
        current = nil
        let duration = s.last.elapsed ?? 0
        guard duration >= minimumDuration else { return nil }
        var r = WorkoutRecord(start: s.start, end: now, duration: duration, distance: s.last.distance ?? 0,
                              calories: s.last.calories ?? 0, steps: s.last.steps ?? 0,
                              maxSpeed: s.maxSpeed, deviceName: deviceName, speedSamples: s.samples,
                              stepSamples: s.stepSamples, runId: s.runId)
        r.partial = partial ? true : nil
        return r
    }
}

/// Totals over a set of workouts ("Active days" on the phone).
public struct ActivitySummary: Equatable, Sendable {
    public var workouts = 0
    public var activeDays = 0
    public var duration = 0
    public var distance = 0
    public var calories = 0
    public var steps = 0

    public init() {}

    public init(_ records: [WorkoutRecord], calendar: Calendar = .current) {
        workouts = records.count
        activeDays = Set(records.map { calendar.startOfDay(for: $0.start) }).count
        duration = records.reduce(0) { $0 + $1.duration }
        distance = records.reduce(0) { $0 + $1.distance }
        calories = records.reduce(0) { $0 + $1.calories }
        steps = records.reduce(0) { $0 + $1.steps }
    }

    /// Records whose start falls on the same day / month as `date`.
    public static func filter(_ records: [WorkoutRecord], sameDayAs date: Date, calendar: Calendar = .current) -> [WorkoutRecord] {
        records.filter { calendar.isDate($0.start, inSameDayAs: date) }
    }

    public static func filter(_ records: [WorkoutRecord], sameMonthAs date: Date, calendar: Calendar = .current) -> [WorkoutRecord] {
        records.filter { calendar.isDate($0.start, equalTo: date, toGranularity: .month) }
    }

    /// Daily totals for the last `days` days, oldest first (for the bar chart).
    public static func daily(_ records: [WorkoutRecord], days: Int, until end: Date = Date(),
                             calendar: Calendar = .current) -> [(day: Date, summary: ActivitySummary)] {
        let last = calendar.startOfDay(for: end)
        return (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: last) else { return nil }
            return (day, ActivitySummary(filter(records, sameDayAs: day, calendar: calendar), calendar: calendar))
        }
    }
}

/// JSON file store in Application Support. Writes go to a temporary file first, so a crash mid-write
/// never leaves a corrupt history.
public final class WorkoutStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenTreadmill", isDirectory: true).appendingPathComponent("workouts.json")
    }

    public func load() -> [WorkoutRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([WorkoutRecord].self, from: data)) ?? []
    }

    public func save(_ records: [WorkoutRecord]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(records).write(to: url, options: .atomic)
    }
}
