import AppKit
import TreadmillKit

/// Owns the treadmill connection, the workout history and the user's programs.
@MainActor
final class AppModel: ObservableObject {
    let treadmill = TreadmillManager()
    @Published private(set) var workouts: [WorkoutRecord] = []
    @Published private(set) var saveError: String?
    @Published private(set) var programs: [WorkoutProgram] = []

    private let store = WorkoutStore(url: WorkoutStore.defaultURL())
    private let programStore = ProgramStore(url: ProgramStore.defaultURL())

    init() {
        workouts = store.load().sorted { $0.start > $1.start }
        programs = programStore.load()
        treadmill.onWorkoutFinished = { [weak self] rec in self?.add(rec) }
        // Quitting mid-walk saves the walk so far (the belt keeps running; the next launch merges the rest).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.treadmill.saveRunningWorkout() }
        }
    }

    func saveProgram(_ p: WorkoutProgram) {
        if let i = programs.firstIndex(where: { $0.id == p.id }) { programs[i] = p } else { programs.append(p) }
        try? programStore.save(programs)
    }

    func deleteProgram(_ id: WorkoutProgram.ID) {
        programs.removeAll { $0.id == id }
        try? programStore.save(programs)
    }

    func add(_ rec: WorkoutRecord) {
        workouts.addMerging(rec)
        workouts.sort { $0.start > $1.start }
        persist()
    }

    func delete(_ ids: Set<WorkoutRecord.ID>) {
        workouts.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        do {
            try store.save(workouts)
            saveError = nil
        } catch {
            saveError = "Could not save history: \(error.localizedDescription)"
        }
    }
}

enum Format {
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    static func km(_ metres: Int) -> String { String(format: "%.2f", Double(metres) / 1000) }

    static func speed(_ kmh: Double) -> String { String(format: "%.1f", kmh) }

    /// "1 h 53 min" / "39 min".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    /// Seconds per km as 20'22".
    static func pace(_ secondsPerKm: Double) -> String {
        let s = Int(secondsPerKm.rounded())
        return String(format: "%d'%02d\"", s / 60, s % 60)
    }

    /// 3 -> "3", 2.5 -> "2.5".
    static func amount(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
