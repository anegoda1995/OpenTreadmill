import Charts
import SwiftUI
import TreadmillKit

// MARK: - Programs page

struct ProgramsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var treadmill: TreadmillManager
    @State private var selection: WorkoutProgram.ID? = WorkoutProgram.templates.first?.id
    @State private var editing: WorkoutProgram?

    private var all: [WorkoutProgram] { WorkoutProgram.templates + model.programs }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Templates") {
                    ForEach(WorkoutProgram.templates) { ProgramRow(program: $0).tag($0.id) }
                }
                Section("My programs") {
                    ForEach(model.programs) { p in
                        ProgramRow(program: p).tag(p.id)
                            .contextMenu {
                                Button("Edit") { editing = p }
                                Button("Delete", role: .destructive) { model.deleteProgram(p.id) }
                            }
                    }
                    Button {
                        editing = WorkoutProgram(name: "My program", segments: [.init(minutes: 5, speed: 3.0), .init(minutes: 10, speed: 4.0), .init(minutes: 5, speed: 3.0)])
                    } label: {
                        Label("New program", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(minWidth: 260, idealWidth: 300)

            Group {
                if let id = selection, let p = all.first(where: { $0.id == id }) {
                    ProgramDetail(program: p, onEdit: p.builtIn ? nil : { editing = p }, onCopy: {
                        var c = p
                        c.id = UUID()
                        c.builtIn = false
                        c.name = "\(p.name) (copy)"
                        editing = c
                    })
                } else {
                    ContentUnavailableView("Select a program", systemImage: "chart.bar.xaxis")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Programs")
        .sheet(item: $editing) { p in
            ProgramEditor(program: p) { saved in
                model.saveProgram(saved)
                selection = saved.id
            }
        }
    }
}

struct ProgramRow: View {
    let program: WorkoutProgram
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(program.name).font(.headline)
            Text("\(program.totalSeconds / 60) min \u{00B7} up to \(Format.speed(program.maxSpeed)) km/h \u{00B7} ~\(Format.km(program.plannedDistance)) km")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProgramDetail: View {
    @EnvironmentObject var treadmill: TreadmillManager
    let program: WorkoutProgram
    var onEdit: (() -> Void)?
    var onCopy: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(program.name).font(.largeTitle.bold())
                stats
                ProgramChart(program: program, current: nil).frame(height: 180)
                limitWarning
                actions
                segmentTable
            }
            .padding(20)
        }
    }

    private var stats: some View {
        HStack(spacing: 30) {
            Total(value: "\(program.totalSeconds / 60)", label: "min")
            Total(value: Format.km(program.plannedDistance), label: "km (planned)")
            Total(value: Format.speed(program.maxSpeed), label: "top km/h")
            Total(value: "\(program.segments.count)", label: "segments")
        }
    }

    @ViewBuilder private var limitWarning: some View {
        if program.maxSpeed > treadmill.speedLimit {
            Label("Segments above your \(Format.speed(treadmill.speedLimit)) km/h limit will run at the limit.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var actions: some View {
        HStack {
            Button {
                treadmill.startProgram(program)
            } label: {
                Label("Start program", systemImage: "play.fill").frame(width: 180, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!treadmill.isReady || treadmill.isBusy)
            if let onEdit { Button("Edit", action: onEdit) }
            Button("Duplicate", action: onCopy)
        }
    }

    private var segmentTable: some View {
        let rows: [(offset: Int, element: ProgramSegment)] = Array(program.segments.enumerated()).map { ($0.offset, $0.element) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.offset) { r in
                HStack {
                    Text("\(r.offset + 1).").frame(width: 28, alignment: .trailing).foregroundStyle(.secondary)
                    Text("\(Format.amount(Double(r.element.seconds) / 60)) min").frame(width: 80, alignment: .leading)
                    Text("\(Format.speed(r.element.speed)) km/h")
                }
                .monospacedDigit()
            }
        }
    }
}

/// Step chart of the speed plan; highlights the running segment.
struct ProgramChart: View {
    let program: WorkoutProgram
    let current: Int?

    private var steps: [(index: Int, start: Double, end: Double, speed: Double)] {
        var t = 0.0
        return program.segments.enumerated().map { i, s in
            defer { t += Double(s.seconds) / 60 }
            return (i, t, t + Double(s.seconds) / 60, s.speed)
        }
    }

    var body: some View {
        Chart(steps, id: \.index) { s in
            RectangleMark(xStart: .value("Start", s.start), xEnd: .value("End", s.end),
                          yStart: .value("Zero", 0), yEnd: .value("km/h", s.speed))
                .foregroundStyle(s.index == current ? Color.green : Color.accentColor.opacity(current == nil ? 0.8 : 0.35))
        }
        .chartXAxisLabel("minutes")
        .chartYAxisLabel("km/h")
    }
}

struct ProgramEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var program: WorkoutProgram
    let onSave: (WorkoutProgram) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $program.name).font(.title3)
            ProgramChart(program: program, current: nil).frame(height: 120)
            List {
                ForEach(program.segments.indices, id: \.self) { i in
                    HStack {
                        Text("\(i + 1).").frame(width: 24, alignment: .trailing).foregroundStyle(.secondary)
                        TextField("min", value: Binding(
                            get: { Double(program.segments[i].seconds) / 60 },
                            set: { program.segments[i].seconds = max(10, Int($0 * 60)) }), format: .number)
                            .frame(width: 60)
                        Text("min")
                        Stepper(value: $program.segments[i].speed, in: 1...18, step: 0.1) {
                            Text("\(Format.speed(program.segments[i].speed)) km/h").monospacedDigit().frame(width: 80)
                        }
                        Spacer()
                        Button(role: .destructive) { program.segments.remove(at: i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(program.segments.count == 1)
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button {
                    program.segments.append(program.segments.last ?? .init(minutes: 5, speed: 3))
                } label: { Label("Add segment", systemImage: "plus") }
                Spacer()
                Text("\(program.totalSeconds / 60) min").foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }
                Button("Save") {
                    program.builtIn = false
                    onSave(program)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(program.name.trimmingCharacters(in: .whitespaces).isEmpty || program.segments.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

// MARK: - Program panel on the Workout page

struct ProgramPanel: View {
    @EnvironmentObject var treadmill: TreadmillManager
    let program: WorkoutProgram

    var body: some View {
        let t = treadmill.programTime
        let pos = program.position(at: t)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(program.name, systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                if treadmill.programFinished {
                    Text("Finished").foregroundStyle(.green).bold()
                } else if let pos {
                    let seg = program.segments[pos.index]
                    Text("Segment \(pos.index + 1)/\(program.segments.count): \(Format.speed(seg.speed)) km/h, \(Format.clock(pos.remaining).dropFirst(3)) left")
                        .monospacedDigit()
                    if pos.index + 1 < program.segments.count {
                        Text("then \(Format.speed(program.segments[pos.index + 1].speed))")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("End program") { treadmill.stopProgram() }
            }
            ProgramChart(program: program, current: treadmill.programFinished ? nil : pos?.index)
                .frame(height: 70)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
            ProgressView(value: Double(min(t, program.totalSeconds)), total: Double(max(1, program.totalSeconds)))
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
