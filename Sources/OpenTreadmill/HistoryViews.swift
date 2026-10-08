import AppKit
import Charts
import SwiftUI
import TreadmillKit

// MARK: - History ("Workout" in the phone's Profile tab)

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: WorkoutRecord.ID?
    @State private var period: Period = .month
    @State private var sortOrder = [KeyPathComparator(\WorkoutRecord.start, order: .reverse)]

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", month = "Month", total = "Total"
        var id: String { rawValue }
    }

    private var rows: [WorkoutRecord] { model.workouts.sorted(using: sortOrder) }

    var body: some View {
        VStack(spacing: 0) {
            ActiveDaysCard(period: $period)
                .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            if model.workouts.isEmpty {
                ContentUnavailableView("No workouts yet", systemImage: "figure.walk",
                                       description: Text("Workouts are saved here when the belt stops."))
            } else {
                HSplitView {
                    WorkoutTable(rows: rows, selection: $selection, sortOrder: $sortOrder)
                        .frame(minWidth: 400, idealWidth: 460)
                    Group {
                        if let id = selection, let w = model.workouts.first(where: { $0.id == id }) {
                            WorkoutDetailView(record: w)
                        } else {
                            ContentUnavailableView("Select a workout", systemImage: "chart.xyaxis.line")
                        }
                    }
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let e = model.saveError { Text(e).foregroundStyle(.red).padding(6) }
        }
        .navigationTitle("History")
        .onAppear { if selection == nil { selection = rows.first?.id } }
    }
}

struct WorkoutTable: View {
    @EnvironmentObject var model: AppModel
    let rows: [WorkoutRecord]
    @Binding var selection: WorkoutRecord.ID?
    @Binding var sortOrder: [KeyPathComparator<WorkoutRecord>]

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.start) { Text($0.start, format: .dateTime.year(.twoDigits).month(.twoDigits).day().hour().minute()) }
                .width(min: 110, ideal: 120)
            TableColumn("Time", value: \.duration) { Text(Format.clock($0.duration)).monospacedDigit() }.width(62)
            TableColumn("km", value: \.distance) { Text(Format.km($0.distance)).monospacedDigit() }.width(46)
            TableColumn("kcal", value: \.calories) { Text("\($0.calories)").monospacedDigit() }.width(40)
            TableColumn("Steps", value: \.steps) { Text("\($0.steps)").monospacedDigit() }.width(52)
            TableColumn("km/h") { Text(Format.speed($0.averageSpeed)).monospacedDigit() }.width(38)
            TableColumn("Pace") { Text($0.pace.map(Format.pace) ?? "-").monospacedDigit() }.width(48)
            TableColumn("Src") { r in
                if !r.speedSamples.isEmpty {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary).help("Has per-second data")
                }
            }
            .width(36)
        }
        .font(.callout)
        .contextMenu(forSelectionType: WorkoutRecord.ID.self) { ids in
            Button("Delete from this Mac", role: .destructive) { model.delete(ids) }
        }
    }
}

/// Totals for today, this month or everything, plus distance per day for the last 14 days.
struct ActiveDaysCard: View {
    @EnvironmentObject var model: AppModel
    @Binding var period: HistoryView.Period

    private var records: [WorkoutRecord] {
        switch period {
        case .today: ActivitySummary.filter(model.workouts, sameDayAs: Date())
        case .month: ActivitySummary.filter(model.workouts, sameMonthAs: Date())
        case .total: model.workouts
        }
    }

    var body: some View {
        let s = ActivitySummary(records)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: $period) {
                    ForEach(HistoryView.Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow { mini(Format.km(s.distance), "km"); mini("\(s.duration / 60)", "min"); mini("\(s.calories)", "kcal") }
                    GridRow { mini("\(s.steps)", "steps"); mini("\(s.workouts)", "workouts"); mini("\(s.activeDays)", "days") }
                }
            }
            DailyDistanceChart(records: model.workouts)
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 90)
        }
    }

    private func mini(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(v).font(.callout.bold()).monospacedDigit()
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct DailyDistanceChart: View {
    let records: [WorkoutRecord]

    var body: some View {
        let days = ActivitySummary.daily(records, days: 21)
        Chart(days, id: \.day) { d in
            BarMark(x: .value("Day", d.day, unit: .day), y: .value("km", Double(d.summary.distance) / 1000))
                .foregroundStyle(Color.accentColor.gradient)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.caption2)
            }
        }
        .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel().font(.caption2) } }
    }
}

struct WorkoutRow: View {
    let record: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Free workout", systemImage: "figure.walk").font(.headline)
                Spacer()
                if !record.speedSamples.isEmpty {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary).help("Recorded on this Mac")
                }
                Text(record.start, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Text("\(Format.km(record.distance)) km").bold()
                Text("\(record.calories) kcal")
                Text(Format.duration(record.duration))
            }
            .monospacedDigit()
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

/// The phone's workout report: summary, pace, speed and cadence. Dense: label/value grid, small charts.
struct WorkoutDetailView: View {
    let record: WorkoutRecord
    @State private var shareURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Format.km(record.distance)).font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text("km").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(record.deviceName.isEmpty ? "Treadmill" : record.deviceName) \u{00B7} Free workout").font(.callout.bold())
                        Text(record.start, format: .dateTime.weekday().day().month().year().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let url = shareURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.help("Share as image")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow { kv("Time", Format.clock(record.duration)); kv("kcal", "\(record.calories)"); kv("Steps", "\(record.steps)") }
                    GridRow { kv("Pace", record.pace.map(Format.pace) ?? "-"); kv("Avg km/h", Format.speed(record.averageSpeed)); kv("Top km/h", record.maxSpeed > 0 ? Format.speed(record.maxSpeed) : "-") }
                    GridRow { kv("Cadence", "\(Int(record.cadence.rounded())) spm"); kv("Stride", record.stride.map { "\(Int($0.rounded())) cm" } ?? "-"); kv("End", record.end.formatted(date: .omitted, time: .shortened)) }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                if !record.speedSamples.isEmpty {
                    ChartCard(title: "Speed, km/h", systemImage: "speedometer") { SpeedChart(record: record, axisLabels: false) }
                }
                let cadence = record.cadenceSeries()
                if !cadence.isEmpty {
                    ChartCard(title: "Cadence, steps/min", systemImage: "shoeprints.fill") {
                        Chart(cadence, id: \.minute) { p in
                            PointMark(x: .value("Minute", p.minute), y: .value("spm", p.spm))
                                .symbolSize(12)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if record.speedSamples.isEmpty {
                    Text("No per-second data for this workout.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .task(id: record) { shareURL = ShareCard.png(for: record) }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.callout.monospacedDigit().bold()).lineLimit(1).fixedSize()
            Text(k).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption.bold())
            content.frame(height: 120)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SpeedChart: View {
    let record: WorkoutRecord
    var axisLabels = true

    /// One point per 10 s keeps long runs light.
    private var points: [(minute: Double, kmh: Double)] {
        Swift.stride(from: 0, to: record.speedSamples.count, by: 10).map { (Double($0) / 60, record.speedSamples[$0]) }
    }

    var body: some View {
        Chart(points, id: \.minute) { p in
            AreaMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh))
                .foregroundStyle(Color.teal.opacity(0.25).gradient)
            LineMark(x: .value("Minute", p.minute), y: .value("km/h", p.kmh))
                .foregroundStyle(.teal)
        }
        .chartXAxisLabel(axisLabels ? "minutes" : "")
        .chartYAxisLabel(axisLabels ? "km/h" : "")
    }
}

struct Total: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Share image (the phone's "share poster")

/// A square summary card rendered to PNG for sharing.
struct ShareCard: View {
    let record: WorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "figure.walk").font(.system(size: 34, weight: .bold))
                Text("OpenTreadmill").font(.title.bold())
                Spacer()
                Text(record.start, format: .dateTime.day().month(.wide).year()).font(.title3)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.km(record.distance)).font(.system(size: 110, weight: .heavy, design: .rounded))
                Text("km").font(.system(size: 40, weight: .bold))
            }
            HStack(spacing: 40) {
                stat(Format.clock(record.duration), "time")
                stat("\(record.calories)", "kcal")
                stat("\(record.steps)", "steps")
                stat(record.pace.map(Format.pace) ?? "-", "pace")
            }
            if !record.speedSamples.isEmpty {
                SpeedChart(record: record, axisLabels: false).frame(height: 140).chartXAxis(.hidden).chartYAxis(.hidden)
            }
        }
        .foregroundStyle(.white)
        .padding(44)
        .frame(width: 900, height: 900)
        .background(LinearGradient(colors: [Color(red: 0.2, green: 0.78, blue: 0.55), Color(red: 0.16, green: 0.42, blue: 0.95)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) {
            Text(v).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            Text(l).font(.title3).opacity(0.85)
        }
    }

    /// PNG in the temporary folder, for ShareLink.
    @MainActor static func png(for record: WorkoutRecord) -> URL? {
        let r = ImageRenderer(content: ShareCard(record: record))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenTreadmill \(Format.km(record.distance)) km.png")
        try? png.write(to: url)
        return url
    }
}
