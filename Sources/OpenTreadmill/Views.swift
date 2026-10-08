import Charts
import SwiftUI
import TreadmillKit

enum Page: String, CaseIterable, Identifiable {
    case workout = "Workout"
    case programs = "Programs"
    case history = "History"
    case device = "Treadmill"
    case log = "Bluetooth log"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workout: "figure.walk"
        case .programs: "chart.bar.xaxis"
        case .history: "list.bullet.rectangle"
        case .device: "gearshape"
        case .log: "text.alignleft"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var treadmill: TreadmillManager
    // `open OpenTreadmill.app --args -page History` opens a page directly (used for screenshots).
    @State private var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .workout

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(190)
            ConnectionBadge().padding(10)
        } detail: {
            switch page ?? .workout {
            case .workout: WorkoutView()
            case .programs: ProgramsView()
            case .history: HistoryView()
            case .device: DeviceView()
            case .log: LogView()
            }
        }
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch treadmill.link {
        case .connected: .green
        case .connecting, .scanning: .orange
        case .handedOver: .blue
        case .asleep: .gray
        default: .red
        }
    }

    private var text: String {
        switch treadmill.link {
        case .bluetoothOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth access denied (System Settings > Privacy)"
        case .idle: "Not connected"
        case .scanning: "Searching for treadmill..."
        case .connecting(let n): "Connecting to \(n)..."
        case .connected(let n): n
        case .handedOver: "Handed over to the phone"
        case .asleep: "Asleep. Wake it with its button or the remote."
        }
    }
}

// MARK: - Workout

struct WorkoutView: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        ScrollView {
            content.padding(.horizontal, 14).padding(.vertical, 10)
        }
        // Speed and Start/Pause/Stop stay on screen whatever the window size: Stop must never need a scroll.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                SpeedControl()
                ControlButtons()
                if let e = treadmill.lastError {
                    Text(e).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle("Workout")
    }

    private var content: some View {
        VStack(spacing: 10) {
            if !treadmill.isReady {
                ConnectPanel()
            }
            if let p = treadmill.program {
                ProgramPanel(program: p)
            } else {
                GoalPanel()
            }
            LiveGrid()
            TodayStrip()
            LiveSpeedChart()
        }
    }
}

/// Eight live numbers in a 4 x 2 grid (dense on purpose: everything at a glance from the treadmill).
struct LiveGrid: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        let t = treadmill.live
        let elapsed = t.elapsed ?? 0, dist = t.distance ?? 0, steps = t.steps ?? 0
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Metric(value: Format.km(dist), label: "km")
                Metric(value: Format.clock(elapsed), label: "time")
                Metric(value: Format.speed(t.speed), label: "km/h now")
                Metric(value: "\(t.calories ?? 0)", label: "kcal")
            }
            GridRow {
                Metric(value: "\(steps)", label: "steps")
                Metric(value: dist > 0 ? Format.pace(Double(elapsed) / (Double(dist) / 1000)) : "-", label: "pace /km")
                Metric(value: elapsed > 0 ? Format.speed(Double(dist) / Double(elapsed) * 3.6) : "-", label: "avg km/h")
                Metric(value: elapsed > 0 ? "\(Int((Double(steps) / (Double(elapsed) / 60)).rounded()))" : "-", label: "steps/min")
            }
        }
    }
}

struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct SpeedControl: View {
    @EnvironmentObject var treadmill: TreadmillManager
    /// A preset that raises the speed by more than this asks for a second click.
    private let bigJump = 2.0
    private let presets: [Double] = [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0]
    @State private var confirming: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                StepButton(title: "-0.5") { treadmill.nudgeSpeed(by: -0.5) }
                StepButton(title: "-0.1") { treadmill.nudgeSpeed(by: -0.1) }
                VStack(spacing: 0) {
                    Text(Format.speed(treadmill.targetSpeed))
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("target km/h").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 100)
                StepButton(title: "+0.1") { treadmill.nudgeSpeed(by: 0.1) }
                StepButton(title: "+0.5") { treadmill.nudgeSpeed(by: 0.5) }
            }

            HStack(spacing: 6) {
                ForEach(presets.filter { $0 <= treadmill.speedLimit + 0.001 }, id: \.self) { v in
                    Button { tap(v) } label: {
                        Text(confirming == v ? "Again: \(Format.speed(v))" : Format.speed(v))
                            .font(.body.monospacedDigit())
                            .frame(minWidth: 48, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(confirming == v ? .orange : nil)
                }
                Text("limit \(Format.speed(treadmill.speedLimit))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .disabled(!treadmill.isReady)
    }

    private func tap(_ v: Double) {
        let from = treadmill.belt.phase == .running ? max(treadmill.targetSpeed, treadmill.live.speed) : treadmill.targetSpeed
        if v - from > bigJump && confirming != v {
            confirming = v
            Task { try? await Task.sleep(for: .seconds(3)); if confirming == v { confirming = nil } }
            return
        }
        confirming = nil
        treadmill.setSpeed(v)
    }
}

/// Big speed step button with its value written on it.
struct StepButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold).monospacedDigit())
                .frame(minWidth: 76, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

struct ControlButtons: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        HStack(spacing: 16) {
            Button { treadmill.primaryAction() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
                    Text(title)
                }
                .font(.title3.weight(.semibold))
                .frame(width: 260, height: 36)
            }
            .keyboardShortcut(.space, modifiers: [])
            .tint(treadmill.belt.phase == .running ? .orange : .green)
            .disabled(!treadmill.isReady || busy)

            Button(role: .destructive) { treadmill.stopAll() } label: {
                Label(treadmill.belt.isStopping ? "Stopping..." : "Stop", systemImage: "stop.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 170, height: 36)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .tint(.red)
            .disabled(!treadmill.isReady)

            Button { treadmill.sleep() } label: {
                Label("Sleep", systemImage: "moon.zzz.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: 110, height: 36)
            }
            .tint(.indigo)
            .disabled(!treadmill.canSleep)
            .help("Switches the treadmill off. Stop the belt first; wake it with its button or the remote.")
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    private var busy: Bool { treadmill.isBusy }

    private var title: String {
        let b = treadmill.belt
        if b.isStopping { return "Stopping..." }
        if b.waitsForStandstill { return "Starts when the belt stops" }
        if b.isStarting { return "Starting..." }
        switch b.phase {
        case .running: return "Pause"
        case .paused: return "Resume"
        default: return "Start"
        }
    }

    private var icon: String { treadmill.belt.phase == .running ? "pause.fill" : "play.fill" }
}

struct ConnectPanel: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Turn the treadmill on. If the phone app is connected to it, close the app first: the treadmill talks to one device at a time.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(treadmill.link == .scanning ? "Searching..." : "Search") { treadmill.startScan() }
                        .disabled(treadmill.link == .scanning)
                    if treadmill.link == .scanning { Button("Stop search") { treadmill.stopScan() } }
                }
                ForEach(treadmill.found) { f in
                    HStack {
                        Image(systemName: "figure.walk.motion")
                        Text(f.name).font(.headline)
                        Text("\(f.rssi) dBm").foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect") { treadmill.connect(f.id) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Connect your treadmill", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}

// MARK: - Device

struct DeviceView: View {
    @EnvironmentObject var treadmill: TreadmillManager
    @State private var userIdText = ""
    @State private var confirmChildLock = false

    var body: some View {
        Form {
            Section("Treadmill") {
                LabeledContent("Name", value: treadmill.deviceName.isEmpty ? "-" : treadmill.deviceName)
                LabeledContent("Firmware", value: treadmill.firmware.isEmpty ? "-" : treadmill.firmware)
                LabeledContent("Software", value: treadmill.software.isEmpty ? "-" : treadmill.software)
                LabeledContent("Speed range",
                               value: "\(Format.speed(treadmill.speedRange.min)) to \(Format.speed(treadmill.speedRange.max)) km/h")
                LabeledContent("KingSmith unlock", value: treadmill.unlocked ? "OK" : "-")
                LabeledContent("Control granted", value: treadmill.hasControl ? "Yes" : "No")
            }
            Section {
                Stepper(value: $treadmill.speedLimit, in: treadmill.speedRange.min...treadmill.speedRange.max, step: 0.5) {
                    LabeledContent("Speed limit", value: "\(Format.speed(treadmill.speedLimit)) km/h")
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("The app never asks for more than this. The treadmill's own remote is not limited.")
            }
            if let p = treadmill.properties {
                Section("Settings stored on the treadmill") {
                    LabeledContent("Units", value: p.metric ? "Metric" : "Imperial")
                    if p.soundSupported {
                        Toggle("Buzzer (beeps)", isOn: Binding(get: { p.soundOn }, set: { treadmill.setSound($0) }))
                    }
                    if p.lightSupported {
                        Toggle("Marquee light", isOn: Binding(get: { p.lightOn }, set: { treadmill.setLight($0) }))
                    }
                    Toggle("Child lock", isOn: Binding(get: { p.childLockOn }, set: { on in
                        if on { confirmChildLock = true } else { treadmill.setChildLock(false) }
                    }))
                    if p.autoStopTimeSettable {
                        Picker("Idle shutdown", selection: Binding(
                            get: { p.autoStopEnabled ? p.autoStopMinutes : 0 },
                            set: { treadmill.setIdleShutdown(minutes: $0 == 0 ? nil : $0) })) {
                            Text("Off").tag(0)
                            ForEach([10, 20, 30, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                            if p.autoStopEnabled && ![10, 20, 30, 60, 90, 120].contains(p.autoStopMinutes) {
                                Text("\(p.autoStopMinutes) min").tag(p.autoStopMinutes)
                            }
                        }
                    }
                    LabeledContent("Fold lock", value: p.foldLockSupported ? (p.foldLockOn ? "On" : "Off") : "-")
                    LabeledContent("Max speed", value: p.maxSpeed.map { "\(Format.speed($0)) km/h" } ?? "-")
                    LabeledContent("Error code", value: "\(p.errorCode)")
                }
            }
            Section {
                TextField("Account id", text: $userIdText)
                    .onSubmit { treadmill.userId = UInt32(userIdText) ?? 0 }
            } header: {
                Text("Account")
            } footer: {
                Text("Optional. The treadmill tags its stored runs with this id; the vendor's phone app puts its account id here. Leave it empty if you don't need that.")
            }
            Section {
                HStack {
                    if treadmill.link == .handedOver {
                        Button("Take the treadmill back") { treadmill.takeBack() }
                    } else {
                        Button("Hand over to the phone") { treadmill.handOverToPhone() }
                        Button("Reconnect") { treadmill.disconnect(); treadmill.autoConnect() }
                    }
                    Button("Search for other treadmills") { treadmill.startScan() }
                }
                Text("The treadmill talks to one device at a time. Hand it over to use the phone app; the belt keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Treadmill")
        .confirmationDialog("Turn the child lock on?", isPresented: $confirmChildLock) {
            Button("Lock the treadmill") { treadmill.setChildLock(true) }
        } message: {
            Text("The treadmill's own buttons stop working until the lock is turned off here or in the phone app.")
        }
        .onAppear { userIdText = treadmill.userId == 0 ? "" : "\(treadmill.userId)" }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        ScrollViewReader { proxy in
            List(treadmill.log) { line in
                HStack(alignment: .top) {
                    Text(line.time, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.secondary)
                    Text(line.text).textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
                .id(line.id)
            }
            .onChange(of: treadmill.log.count) {
                if let last = treadmill.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle("Bluetooth log")
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var treadmill: TreadmillManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConnectionBadge()
            if let p = treadmill.program, let pos = p.position(at: treadmill.programTime) {
                Text("\(p.name): segment \(pos.index + 1)/\(p.segments.count), \(Format.speed(p.segments[pos.index].speed)) km/h")
                    .font(.caption)
            } else if let g = treadmill.goal {
                ProgressView(value: g.progress(treadmill.live)) {
                    Text(treadmill.goalReached ? "Goal reached" : "Goal: \(GoalPanel.text(g.kind, g.value))").font(.caption)
                }
            }
            HStack(spacing: 18) {
                Total(value: Format.km(treadmill.live.distance ?? 0), label: "km")
                Total(value: Format.clock(treadmill.live.elapsed ?? 0), label: "time")
                Total(value: Format.speed(treadmill.live.speed), label: "km/h")
                Total(value: "\(treadmill.live.steps ?? 0)", label: "steps")
            }
            HStack {
                Button("-0.5") { treadmill.nudgeSpeed(by: -0.5) }
                Text("\(Format.speed(treadmill.targetSpeed)) km/h").monospacedDigit().frame(width: 80)
                Button("+0.5") { treadmill.nudgeSpeed(by: 0.5) }
                Spacer()
                Button { treadmill.primaryAction() } label: {
                    Image(systemName: treadmill.belt.phase == .running ? "pause.fill" : "play.fill")
                }
                .disabled(treadmill.isBusy)
                Button { treadmill.stopAll() } label: { Image(systemName: "stop.fill") }.tint(.red)
                Button { treadmill.sleep() } label: { Image(systemName: "moon.zzz.fill") }
                    .disabled(!treadmill.canSleep)
                    .help("Sleep: switches the treadmill off")
            }
            .disabled(!treadmill.isReady)
            Divider()
            if treadmill.link == .handedOver {
                Button("Take the treadmill back from the phone") { treadmill.takeBack() }
            } else if treadmill.isReady {
                Button("Hand over to the phone") { treadmill.handOverToPhone() }
            }
            HStack {
                Button("Open OpenTreadmill") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
