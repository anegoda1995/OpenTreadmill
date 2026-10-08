import CoreBluetooth
import Foundation
import TreadmillKit

/// CoreBluetooth side of the app: finds the KingSmith treadmill, runs the opening handshake, publishes live
/// data and sends control commands.
@MainActor
final class TreadmillManager: NSObject, ObservableObject {
    enum Link: Equatable {
        case bluetoothOff
        case unauthorized
        case idle
        case scanning
        case connecting(String)
        case connected(String)
        /// Released for the phone: no reconnect until the user takes it back.
        case handedOver
        /// Sent to sleep from the app; reconnects when the treadmill is woken up.
        case asleep
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    // MARK: Published state

    @Published private(set) var link: Link = .idle
    @Published private(set) var found: [Found] = []
    @Published private(set) var live = TreadmillData()
    /// Belt phase and the user's pending intent; decides every control command (BeltController).
    @Published private(set) var belt = BeltController()
    @Published private(set) var speedRange = SpeedRange.x218
    @Published private(set) var properties: DeviceProperties?
    @Published private(set) var firmware = ""
    @Published private(set) var software = ""
    @Published private(set) var unlocked = false
    @Published private(set) var hasControl = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [LogLine] = []
    /// The speed the user asked for; the belt reaches it over a few seconds.
    @Published var targetSpeed: Double = 3.0
    /// Goal for the current or next run; the belt stops when it is reached.
    @Published private(set) var goal: WorkoutGoal?
    @Published private(set) var goalReached = false
    /// Interval program in progress (speeds already capped at the limit).
    @Published private(set) var program: WorkoutProgram?
    @Published private(set) var programIndex = 0
    @Published private(set) var programFinished = false
    /// Treadmill elapsed time when the program started.
    private var programStartElapsed = 0
    /// Highest speed the app will ask for (Treadmill page). A safeguard for a walking desk.
    @Published var speedLimit: Double = UserDefaults.standard.object(forKey: "speedLimit") as? Double ?? 6.0 {
        didSet {
            UserDefaults.standard.set(speedLimit, forKey: "speedLimit")
            if targetSpeed > speedLimit { targetSpeed = clampSpeed(targetSpeed) }
        }
    }

    /// Account id sent in the handshake. The treadmill tags its stored runs with it; the vendor's phone app
    /// uses its account id here. 0 when not set.
    var userId: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "treadmillUserId")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "treadmillUserId") }
    }

    var onWorkoutFinished: ((WorkoutRecord) -> Void)?

    // MARK: Private

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var pendingServices = 0
    private var recorder = WorkoutRecorder()
    private var wantScan = false
    private var queue = ControlQueue()
    private var pumpTimer: Timer?
    /// Last time the user changed the target speed; treadmill echoes do not overwrite it for a moment.
    private var userSpeedAt = Date.distantPast
    private var connectWatchdog: Timer?
    private var lastPrimaryTap = Date.distantPast
    private var sleepRequested = false
    private var lastDataLogAt = Date.distantPast
    /// False until the target was taken from the running belt after (re)connecting.
    private var targetSynced = false
    private var advertisedNames: [UUID: String] = [:]
    private var lastDeviceId: UUID? {
        get { UserDefaults.standard.string(forKey: "lastDeviceId").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "lastDeviceId") }
    }

    private static let cp = CBUUID(string: FTMS.controlPoint)
    private static let suppNotify = CBUUID(string: KingsmithProtocol.notify)
    private static let suppWrite = CBUUID(string: KingsmithProtocol.write)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        // Retries after a refusal, countdown timeouts and unanswered commands need a clock.
        pumpTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drive() }
        }
    }

    var deviceName: String {
        guard let p = peripheral else { return "" }
        return advertisedNames[p.identifier] ?? p.name ?? ""
    }
    var isReady: Bool { if case .connected = link { return true } else { return false } }
    /// A start or stop is on its way: the main button waits.
    var isBusy: Bool { belt.isStarting || belt.isStopping }

    // MARK: Scanning and connecting

    func startScan() {
        wantScan = true
        guard central.state == .poweredOn else { return }
        found.removeAll()
        if link != .asleep { link = .scanning }
        // nil services: the X218 name is reliable, and not every firmware lists 0x1826 in its advert.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        note("scan started")
    }

    func stopScan() {
        wantScan = false
        if central.isScanning { central.stopScan() }
        if link == .scanning || link == .asleep { link = .idle }
    }

    func connect(_ id: UUID) {
        guard let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            note("device \(id) not known to CoreBluetooth, scanning")
            startScan()
            return
        }
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        stopScan()
        if link == .asleep { note("treadmill woke up") }
        if let old = peripheral, old !== p { central.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        link = .connecting(p.name ?? "treadmill")
        note("connecting \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
        armConnectWatchdog(for: p)
    }

    /// A pending connect to a remembered peripheral can wait forever (it happens after the treadmill
    /// slept and woke up). After 6 s without an answer: cancel, scan, connect to what the scan finds.
    private func armConnectWatchdog(for p: CBPeripheral) {
        connectWatchdog?.invalidate()
        connectWatchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.peripheral === p, case .connecting = self.link else { return }
                self.note("no answer from the treadmill, scanning again")
                self.central.cancelPeripheralConnection(p)
                self.startScan()
            }
        }
    }

    /// The treadmill talks to one device at a time. This frees it for the phone app and keeps the
    /// Mac from grabbing it back. The belt is not touched.
    func handOverToPhone() {
        note("handing the treadmill over to the phone")
        stopScan()
        connectWatchdog?.invalidate()
        finishWorkout(partial: true)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        link = .handedOver
        UserDefaults.standard.set(true, forKey: "handedOver") // stays handed over after a relaunch
    }

    func takeBack() {
        note("taking the treadmill back")
        UserDefaults.standard.set(false, forKey: "handedOver")
        link = .idle
        autoConnect()
    }

    func disconnect() {
        finishWorkout()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Reconnects to the last treadmill, or scans when there is none.
    func autoConnect() {
        if let id = lastDeviceId { connect(id) } else { startScan() }
    }

    // MARK: Controls

    /// The main button: Start, Pause or Resume. Taps closer than 0.8 s apart are ignored, and the
    /// button does nothing while a start or stop is on its way.
    func primaryAction() {
        let now = Date()
        guard now.timeIntervalSince(lastPrimaryTap) > 0.8 else {
            note("ignored a second click within 0.8 s")
            return
        }
        lastPrimaryTap = now
        guard !belt.isStarting, !belt.isStopping else { return }
        belt.phase == .running ? pause() : start()
    }

    func start() {
        if goalReached || belt.phase == .stopped {
            // A new run: the treadmill counters start from zero again.
            goalReached = false
            if var g = goal { g.baseline = 0; goal = g }
            if programFinished { program = nil; programFinished = false }
            if program != nil { programStartElapsed = 0; programIndex = 0 }
        }
        command(.run(clampSpeed(targetSpeed)))
    }

    /// Sets a goal; during a run it counts from now.
    func setGoal(_ kind: WorkoutGoal.Kind, value: Int) {
        var g = WorkoutGoal(kind: kind, value: value)
        if belt.phase == .running || belt.phase == .paused { g.baseline = g.counter(live) }
        goal = g
        goalReached = false
        note("goal \(kind) \(value)")
    }

    func clearGoal() {
        goal = nil
        goalReached = false
    }

    // MARK: Programs

    /// Program time in seconds (treadmill elapsed time since the program started; pauses don't count).
    var programTime: Int { max(0, (live.elapsed ?? 0) - programStartElapsed) }

    func startProgram(_ p: WorkoutProgram) {
        guard isReady, let first = p.segments.first else { return }
        let capped = p.capped(at: speedLimit)
        clearGoal()
        program = capped
        programIndex = 0
        programFinished = false
        note("program \(p.name), \(p.segments.count) segments")
        if belt.phase == .running || belt.phase == .paused {
            programStartElapsed = live.elapsed ?? 0
            setSpeed(capped.segments[0].speed)
            if belt.phase == .paused { start() }
        } else {
            programStartElapsed = 0 // a fresh run starts the treadmill counters at zero
            targetSpeed = clampSpeed(first.speed)
            start()
        }
    }

    /// The Stop button: ends a running program too (a finished one stays on screen).
    func stopAll() {
        if program != nil && !programFinished { stopProgram() }
        stop()
    }

    func stopProgram() {
        program = nil
        programFinished = false
        note("program cancelled")
    }

    /// Moves to the segment for the current program time; stops the belt after the last one.
    private func runProgram(_ t: TreadmillData) {
        guard let p = program, !programFinished, belt.phase == .running else { return }
        let time = max(0, (t.elapsed ?? 0) - programStartElapsed)
        guard let pos = p.position(at: time) else {
            programFinished = true
            note("program finished")
            stop()
            Notifier.post("\(p.name) finished", "\(Format.km(t.distance ?? 0)) km in \(Format.duration(t.elapsed ?? 0)). The belt is stopping.")
            return
        }
        if pos.index != programIndex {
            programIndex = pos.index
            note("program segment \(pos.index + 1)/\(p.segments.count): \(p.segments[pos.index].speed) km/h")
            setSpeed(p.segments[pos.index].speed)
        }
    }

    // MARK: Treadmill settings (KingSmith supplement, property 8)

    func setSound(_ on: Bool) { sendSupplement(KingsmithProtocol.setSound(on), label: "sound \(on ? "on" : "off")") }

    func setLight(_ on: Bool) { sendSupplement(KingsmithProtocol.setLight(on), label: "light \(on ? "on" : "off")") }

    /// Belt standing still after a Stop, and the treadmill can sleep.
    var canSleep: Bool {
        guard isReady, !isBusy, live.speed == 0, belt.phase == .stopped || belt.phase == .unknown else { return false }
        return properties?.sleepSupported ?? true
    }

    /// Sends the treadmill to sleep (standby). It switches off and drops the Bluetooth link.
    func sleep() {
        guard canSleep else { return }
        finishWorkout()
        sleepRequested = true
        sendSupplement(KingsmithProtocol.sleep(), label: "sleep")
    }

    func setChildLock(_ on: Bool) { sendSupplement(KingsmithProtocol.setChildLock(on), label: "child lock \(on ? "on" : "off")") }

    func setIdleShutdown(minutes: Int?) {
        sendSupplement(KingsmithProtocol.setIdleShutdown(minutes: minutes), label: "idle shutdown \(minutes.map { "\($0) min" } ?? "off")")
    }

    func pause() { command(.pause) }

    /// Always allowed. A moving belt is paused first, then stopped (BeltController).
    func stop() { command(.stop) }

    func clampSpeed(_ kmh: Double) -> Double {
        min(speedRange.clamp(kmh), max(speedRange.min, speedLimit))
    }

    /// Speed for a click: slowing down is always allowed; speeding up stops at the limit (or at the
    /// current target, if the treadmill's own remote already went above the limit).
    private func requestedSpeed(_ kmh: Double) -> Double {
        let v = speedRange.clamp(kmh)
        return v <= targetSpeed ? v : min(v, max(speedLimit, targetSpeed))
    }

    /// Updates the target at once. A moving or starting belt gets it; a paused or stopped belt keeps
    /// it for the next Start (a speed click never starts the belt).
    func setSpeed(_ kmh: Double) {
        let v = requestedSpeed(kmh)
        targetSpeed = v
        userSpeedAt = Date()
        if belt.phase == .running || belt.isStarting { command(.run(v)) }
    }

    /// Steps from the target the user already picked, not from the belt speed that is still ramping.
    func nudgeSpeed(by delta: Double) {
        setSpeed(targetSpeed + delta)
    }

    private func command(_ intent: BeltController.Intent) {
        guard isReady, chars[Self.cp] != nil else {
            lastError = "Treadmill not connected"
            return
        }
        lastError = nil
        note("you: \(intent)")
        belt.user(intent)
        drive()
    }

    /// Asks the controller for the next command when the queue is free and writes it.
    private func drive() {
        guard let p = peripheral, let c = chars[Self.cp] else { return }
        let now = Date()
        if let lost = queue.expire(now: now) {
            note("no answer to \(lost)")
            if lost != .requestControl { belt.observe(response: lost, result: nil, now: now) }
        }
        if queue.isIdle, let cmd = belt.next(now: now) { queue.enqueue(cmd) }
        if let cmd = queue.next(now: now) {
            write(Data(cmd.bytes), to: c, on: p, label: "FTMS \(cmd)")
        }
        hasControl = queue.hasControl
        if let f = belt.failure, lastError == nil {
            lastError = f
            note(f)
        }
    }

    // MARK: Supplement handshake

    private func sendSupplement(_ data: Data, label: String) {
        guard let p = peripheral, let c = chars[Self.suppWrite] else { return }
        write(data, to: c, on: p, label: label)
    }

    private func write(_ data: Data, to c: CBCharacteristic, on p: CBPeripheral, label: String) {
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: c, type: type)
        note("-> \(label): \(data.hex)")
    }

    private func handleSupplement(_ data: Data) {
        guard let msg = KingsmithMessage.parse(data) else {
            note("<- supplement (bad frame) \(data.hex)")
            return
        }
        note("<- supplement \(msg)")
        switch msg {
        case .unlockOK:
            unlocked = true
            sendSupplement(KingsmithProtocol.systemInfo(unixTime: UInt32(Date().timeIntervalSince1970), userId: userId),
                           label: "system info")
        case .unlockFailed(let code):
            lastError = "Treadmill refused unlock (\(code))"
        case .systemInfo:
            sendSupplement(KingsmithProtocol.readAllProperties(), label: "read properties")
        case .properties(let raw):
            var merged = properties?.raw ?? [:]
            merged.merge(raw) { $1 }
            properties = DeviceProperties(raw: merged)
            if let max = properties?.maxSpeed, max > 0, max < speedRange.max {
                speedRange.max = max
            }
        case .workoutEvent(let n, let run, let uid):
            note("treadmill stored run #\(n) id \(run) for user \(uid)")
            recorder.setRunId(run)
        case .unknown(0x72, 0x50, let payload):
            var r = ByteReader(payload)
            var changed: [UInt16: UInt16] = [:]
            while let id = r.u8(), let v = r.u16() { changed[UInt16(id)] = v }
            note("treadmill settings changed: \(changed)")
            var merged = properties?.raw ?? [:]
            merged.merge(changed) { $1 }
            properties = DeviceProperties(raw: merged)
        case .unknown(0x72, 0x81, _):
            // A settings write was accepted: read them back so the switches show the real state.
            sendSupplement(KingsmithProtocol.readAllProperties(), label: "read properties")
        case .actions, .unknown:
            break
        }
    }

    // MARK: Data handling

    private func handle(_ c: CBCharacteristic) {
        guard let data = c.value else { return }
        switch c.uuid {
        case CBUUID(string: FTMS.treadmillData):
            guard let t = TreadmillData.parse(data) else { return }
            live = t
            belt.observe(speed: t.speed, elapsed: t.elapsed)
            if !targetSynced && belt.phase == .running && t.speed > 0 {
                // Connected to a moving belt: steps must start from its speed, not from the default.
                targetSpeed = (t.speed * 10).rounded() / 10
                targetSynced = true
            }
            logData(t)
            if let rec = recorder.ingest(t, deviceName: deviceName) { onWorkoutFinished?(rec) }
            runProgram(t)
            if let g = goal, !goalReached, belt.phase == .running, g.reached(t) {
                goalReached = true
                note("goal reached: \(g.kind) \(g.value)")
                stop()
                Notifier.post("Goal reached", "\(Format.km(t.distance ?? 0)) km in \(Format.duration(t.elapsed ?? 0)). The belt is stopping.")
            }
            drive()
        case CBUUID(string: FTMS.controlPoint):
            guard let r = ControlResponse.parse(data) else { return }
            note("<- control \(data.hex) \(r.result.map { "\($0)" } ?? "code \(r.rawResult)")")
            switch queue.handle(r) {
            case .done(let cmd) where cmd != .requestControl:
                belt.observe(response: cmd, result: .success)
            case .failed(.requestControl, _):
                lastError = "Treadmill did not grant control"
            case .failed(let cmd, let res):
                // Refused in this phase (or control lost): the controller waits and tries again.
                belt.observe(response: cmd, result: res.result ?? .failed)
            default:
                break
            }
            drive()
        case CBUUID(string: FTMS.machineStatus):
            guard let s = MachineStatus.parse(data) else { return }
            note("<- status \(s)")
            belt.observe(status: s)
            switch s {
            case .stoppedByUser, .stoppedBySafetyKey:
                finishWorkout()
            case .reset:
                // After a reset the treadmill forgets who has control ("not permitted") and the account
                // id (its next runs are stored for id 0): tell it again.
                queue.controlLost()
                hasControl = false
                finishWorkout()
                if unlocked {
                    sendSupplement(KingsmithProtocol.systemInfo(unixTime: UInt32(Date().timeIntervalSince1970), userId: userId),
                                   label: "system info after reset")
                }
            case .targetSpeedChanged(let v):
                // Echo of our command or a change on the treadmill's remote. While the user is clicking
                // the shown target follows the clicks, not the echoes.
                if v > 0, queue.pendingSpeed == nil, Date().timeIntervalSince(userSpeedAt) > 2 {
                    if case .run = belt.intent {} else { targetSpeed = v }
                }
            case .controlPermissionLost:
                queue.controlLost()
                hasControl = false
            default:
                break
            }
            drive()
        case CBUUID(string: FTMS.supportedSpeedRange):
            if let r = SpeedRange.parse(data) { speedRange = r }
        case CBUUID(string: FTMS.firmwareRevision):
            firmware = String(decoding: data, as: UTF8.self)
        case CBUUID(string: FTMS.softwareRevision):
            software = String(decoding: data, as: UTF8.self)
        case Self.suppNotify:
            handleSupplement(data)
        default:
            break
        }
    }

    /// Data lines in the file log: every sample while the belt changes phase or speed, else every 10 s.
    private func logData(_ t: TreadmillData) {
        let transitional = belt.isStarting || belt.isStopping || belt.slowingDown || belt.intent != .none
        guard transitional || Date().timeIntervalSince(lastDataLogAt) >= 10 else { return }
        lastDataLogAt = Date()
        note("data \(Format.speed(t.speed)) km/h, \(t.elapsed ?? 0) s, \(t.distance ?? 0) m, phase \(belt.phase)")
    }

    /// The run in progress that is not in History yet (for today's totals).
    var currentSession: WorkoutRecorder.Session? { recorder.current }

    /// Saves the run in progress without touching the belt (app quit): the walk may go on.
    func saveRunningWorkout() { finishWorkout(partial: true) }

    private func finishWorkout(partial: Bool = false) {
        if let rec = recorder.finish(deviceName: deviceName, partial: partial) { onWorkoutFinished?(rec) }
    }

    private func note(_ s: String) {
        log.append(LogLine(text: s))
        if log.count > 400 { log.removeFirst(log.count - 400) }
        Self.appendToLogFile(s)
    }

    /// ~/Library/Application Support/OpenTreadmill/ble.log, one line per event, for debugging.
    private static let logURL = WorkoutStore.defaultURL().deletingLastPathComponent().appendingPathComponent("ble.log")
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func appendToLogFile(_ s: String) {
        let line = "\(logFormatter.string(from: Date())) \(s)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    private func resetLinkState() {
        chars.removeAll()
        unlocked = false
        hasControl = false
        queue.reset()
        belt.linkReset()
        targetSynced = false
    }
}

// MARK: - CBCentralManagerDelegate

extension TreadmillManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if link == .bluetoothOff || link == .unauthorized { link = .idle }
                if link == .handedOver { break }
                if UserDefaults.standard.bool(forKey: "handedOver") {
                    link = .handedOver
                    break
                }
                if wantScan { startScan() } else if peripheral == nil { autoConnect() }
            case .unauthorized:
                link = .unauthorized
            default:
                link = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData: [String: Any], rssi: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        MainActor.assumeIsolated {
            let name = advName ?? p.name ?? ""
            guard name.hasPrefix("KS-") || services.contains(CBUUID(string: FTMS.service)) else { return }
            if !name.isEmpty { advertisedNames[p.identifier] = name }
            if let i = found.firstIndex(where: { $0.id == p.identifier }) {
                found[i].rssi = rssi.intValue
            } else {
                found.append(Found(id: p.identifier, name: name.isEmpty ? "Treadmill" : name, rssi: rssi.intValue))
                note("found \(name) rssi \(rssi)")
            }
            // Reconnect to the remembered treadmill as soon as it shows up; on first run take the first
            // KingSmith treadmill found.
            if link != .handedOver, p.identifier == lastDeviceId || (lastDeviceId == nil && name.hasPrefix("KS-")) {
                connect(p)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            connectWatchdog?.invalidate()
            sleepRequested = false
            note("connected, discovering services")
            lastDeviceId = p.identifier
            resetLinkState()
            p.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            lastError = "Connection failed: \(error?.localizedDescription ?? "unknown")"
            link = .idle
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            note("disconnected \(error?.localizedDescription ?? "")")
            finishWorkout(partial: belt.phase == .running || belt.phase == .paused)
            resetLinkState()
            if link == .handedOver { return }
            if sleepRequested {
                // Asleep on purpose: wait quietly for it to wake up and advertise again.
                link = .asleep
                startScan()
                return
            }
            link = .idle
            if error != nil {
                // Dropped link (treadmill asleep, out of range): keep looking for it.
                startScan()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TreadmillManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = p.services ?? []
            pendingServices = services.count
            note("services: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
            services.forEach { p.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in s.characteristics ?? [] { chars[c.uuid] = c }
            pendingServices -= 1
            if pendingServices == 0 { runSetup(p) }
        }
    }

    /// Device info reads, FTMS reads and notifications, then the KingSmith service.
    private func runSetup(_ p: CBPeripheral) {
        for id in [FTMS.firmwareRevision, FTMS.softwareRevision, FTMS.manufacturerName, FTMS.feature,
                   FTMS.supportedSpeedRange, FTMS.trainingStatus, FTMS.machineStatus] {
            if let c = chars[CBUUID(string: id)], c.properties.contains(.read) { p.readValue(for: c) }
        }
        for id in [FTMS.treadmillData, FTMS.trainingStatus, FTMS.controlPoint, FTMS.machineStatus] {
            if let c = chars[CBUUID(string: id)] { p.setNotifyValue(true, for: c) }
        }
        if let c = chars[Self.suppNotify] {
            p.setNotifyValue(true, for: c)
        } else {
            note("no KingSmith supplement characteristic; plain FTMS only")
        }
        link = .connected(p.name ?? "Treadmill")
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { note("notify \(c.uuid) failed: \(error.localizedDescription)"); return }
            if c.uuid == Self.suppNotify && c.isNotifying {
                sendSupplement(KingsmithProtocol.unlock(deviceName: deviceName), label: "unlock")
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { note("read \(c.uuid) failed: \(error.localizedDescription)"); return }
            handle(c)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { lastError = "Write failed: \(error.localizedDescription)" }
        }
    }
}
