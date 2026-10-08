import Charts
import SwiftUI
import TreadmillKit

/// The phone's "Target": time, distance or calories. The app stops the belt when it is reached.
struct GoalPanel: View {
    @EnvironmentObject var treadmill: TreadmillManager
    @State private var editing = false

    var body: some View {
        HStack(spacing: 14) {
            if let g = treadmill.goal {
                let p = g.progress(treadmill.live)
                ProgressView(value: p) {
                    HStack {
                        Text(treadmill.goalReached ? "Goal reached" : "Goal: \(Self.text(g.kind, g.value))")
                            .font(.headline)
                        Spacer()
                        Text("\(Self.text(g.kind, g.done(treadmill.live))) \u{00B7} \(Int(p * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .tint(treadmill.goalReached ? .green : .accentColor)
                Button("Change") { editing = true }
                Button("Clear") { treadmill.clearGoal() }
            } else {
                Label("No goal: free workout", systemImage: "target").foregroundStyle(.secondary)
                Spacer()
                Button("Set goal") { editing = true }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .popover(isPresented: $editing, arrowEdge: .bottom) { GoalEditor(done: { editing = false }) }
    }

    static func text(_ kind: WorkoutGoal.Kind, _ v: Int) -> String {
        switch kind {
        case .time: "\(v / 60) min"
        case .distance: "\(Format.km(v)) km"
        case .calories: "\(v) kcal"
        }
    }
}

struct GoalEditor: View {
    @EnvironmentObject var treadmill: TreadmillManager
    let done: () -> Void
    @State private var kind: WorkoutGoal.Kind = .distance
    @State private var amount: Double = 3

    private var presets: [Double] {
        switch kind {
        case .time: [10, 20, 30, 45, 60, 90]
        case .distance: [1, 2, 3, 5, 8, 10]
        case .calories: [100, 200, 300, 500]
        }
    }

    private var unit: String {
        switch kind {
        case .time: "min"
        case .distance: "km"
        case .calories: "kcal"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Workout goal").font(.headline)
            Picker("", selection: $kind) {
                Text("Time").tag(WorkoutGoal.Kind.time)
                Text("Distance").tag(WorkoutGoal.Kind.distance)
                Text("Calories").tag(WorkoutGoal.Kind.calories)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { amount = presets[2] }
            HStack {
                ForEach(presets, id: \.self) { v in
                    Button("\(Format.amount(v))") { amount = v }
                        .buttonStyle(.bordered)
                        .tint(amount == v ? .accentColor : nil)
                }
            }
            HStack {
                TextField("", value: $amount, format: .number).frame(width: 80)
                Text(unit)
                Spacer()
                Button("Cancel", action: done)
                Button("Set goal") {
                    let v: Int
                    switch kind {
                    case .time: v = Int(amount * 60)
                    case .distance: v = Int(amount * 1000)
                    case .calories: v = Int(amount)
                    }
                    treadmill.setGoal(kind, value: v)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(amount <= 0)
            }
            Text("The belt stops when the goal is reached.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Today's totals like the cards on the phone's home screen: saved workouts plus the run in progress.
struct TodayStrip: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        let session = treadmill.currentSession
        // A run saved in parts (app quit mid-run) is counted once: from the live session.
        let todays = ActivitySummary.filter(model.workouts, sameDayAs: Date()).filter { r in
            guard let s = session else { return true }
            if let a = r.runId, let b = s.runId { return a != b }
            return abs(r.start.timeIntervalSince(s.start)) >= 15
        }
        let saved = ActivitySummary(todays)
        let live = session?.last
        let km = Format.km(saved.distance + (live?.distance ?? 0))
        let kcal = saved.calories + (live?.calories ?? 0)
        let steps = saved.steps + (live?.steps ?? 0)
        let minutes = (saved.duration + (live?.elapsed ?? 0)) / 60
        let runs = saved.workouts + (session == nil ? 0 : 1)
        HStack(spacing: 14) {
            Text("Today").bold()
            Text("\(km) km")
            Text("\(kcal) kcal")
            Text("\(steps) steps")
            Text("\(minutes) min")
            Text("\(runs) \(runs == 1 ? "workout" : "workouts")").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct TodayCard: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.bold()).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}


/// Speed of the walk in progress, minute by minute, filling the space under the numbers.
struct LiveSpeedChart: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        let samples = treadmill.currentSession?.samples ?? []
        // One point per 10 s keeps a long walk light to draw.
        let points: [(minute: Double, kmh: Double)] = Swift.stride(from: 0, to: samples.count, by: 10).map {
            (Double($0) / 60, samples[$0])
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("This walk, km/h by minute").font(.caption.bold()).foregroundStyle(.secondary)
            if points.count > 1 {
                Chart(points, id: \.minute) { p in
                    AreaMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh))
                        .foregroundStyle(Color.teal.opacity(0.2).gradient)
                    LineMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh)).foregroundStyle(.teal)
                }
                .chartYScale(domain: 0...max(6, (points.map(\.kmh).max() ?? 0) + 1))
                .frame(minHeight: 120, maxHeight: 260)
            } else {
                Text("Starts drawing after the first 10 seconds of walking.").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
