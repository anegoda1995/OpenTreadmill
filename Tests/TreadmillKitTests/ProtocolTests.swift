import Foundation
import Testing
@testable import TreadmillKit

/// Every vector here is a real frame recorded from an X218, with the value it stands for.
private func d(_ hex: String) -> Data {
    let clean = hex.replacingOccurrences(of: " ", with: "")
    var out = Data()
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2)
        out.append(UInt8(clean[i..<j], radix: 16)!)
        i = j
    }
    return out
}

@Suite struct TreadmillDataTests {
    @Test func runningSample() throws {
        // "parse running data: speed: 300, dist: 570, calorie: 40, time: 721, steps: 1052"
        let t = try #require(TreadmillData.parse(d("84242c013a02002800000000d1021c0400")))
        #expect(t.speed == 3.0)
        #expect(t.distance == 570)
        #expect(t.calories == 40)
        #expect(t.caloriesPerHour == 0)
        #expect(t.elapsed == 721)
        #expect(t.steps == 1052)
        #expect(t.heartRate == nil)
    }

    @Test func truncatedPayloadDoesNotCrash() {
        #expect(TreadmillData.parse(d("8424")) == nil)
        let partial = TreadmillData.parse(d("84242c013a02"))
        #expect(partial?.speed == 3.0)
        #expect(partial?.distance == nil)
    }
}

@Suite struct FTMSReadsTests {
    @Test func speedRange() throws {
        // "minSpeed: 100, speedRange = 1800, speedIncrement = 1"
        let r = try #require(SpeedRange.parse(d("640008070a00")))
        #expect(r == SpeedRange(min: 1.0, max: 18.0, step: 0.1))
        #expect(r.clamp(25) == 18.0)
        #expect(r.clamp(0.2) == 1.0)
        #expect(r.clamp(3.04) == 3.0)
        #expect(r.clamp(3.06) == 3.1)
    }

    @Test func feature() throws {
        // "feature radix string: 1001001000100" -> stepCount true, HR false, incline false
        let f = try #require(MachineFeature.parse(d("4412000001000000")))
        #expect(f.raw == 0b1001001000100)
        #expect(f.stepCount)
        #expect(!f.heartRate)
        #expect(!f.inclination)
        #expect(f.elapsedTime)
    }

    @Test func trainingStatus() {
        #expect(TrainingStatus.parse(d("010d")) == .manualMode)
    }

    @Test func controlCommandsMatchCapture() {
        #expect(ControlCommand.requestControl.bytes == [0x00])
        #expect(ControlCommand.setSpeed(3.0).bytes == [0x02, 0x2C, 0x01])
        #expect(ControlCommand.pause.bytes == [0x08, 0x02])
        #expect(ControlCommand.stop.bytes == [0x08, 0x01])
        #expect(ControlCommand.startOrResume.bytes == [0x07])
        #expect(ControlCommand.targetDistance(5000).bytes == [0x0C, 0x88, 0x13, 0x00])
    }

    @Test func controlResponses() {
        #expect(ControlResponse.parse(d("800001")) == ControlResponse(requestOpcode: 0, result: .success, rawResult: 1))
        #expect(ControlResponse.parse(d("8002012c01"))?.requestOpcode == 0x02)
        #expect(ControlResponse.parse(d("8002012c01"))?.result == .success)
        #expect(ControlResponse.parse(d("0102")) == nil)
    }

    @Test func machineStatus() {
        #expect(MachineStatus.parse(d("0202")) == .pausedByUser)
        #expect(MachineStatus.parse(d("0201")) == .stoppedByUser)
        #expect(MachineStatus.parse(d("04")) == .startedOrResumed)
        #expect(MachineStatus.parse(d("052c01")) == .targetSpeedChanged(3.0))
    }
}

@Suite struct SupplementTests {
    @Test func unlockMatchesCapture() {
        // Recorded handshake to KS-NG-X18F3 with random byte 0x5B: 71 00 05 5B 8C 38 46 33 0E.
        #expect(KingsmithProtocol.unlock(deviceName: "KS-NG-X18F3", random: 0x5B) == d("7100055b8c3846330e"))
    }

    @Test func systemInfoMatchesCapture() {
        #expect(KingsmithProtocol.systemInfo(unixTime: 1_800_000_000, userId: 1_234_567) == d("71010800d2496b87d612006f"))
    }

    @Test func fixedRequests() {
        #expect(KingsmithProtocol.readAllProperties() == d("7200000072"))
        #expect(KingsmithProtocol.actionList() == d("75000075"))
    }

    @Test func parseReplies() {
        #expect(KingsmithMessage.parse(d("718000f1")) == .unlockOK)
        #expect(KingsmithMessage.parse(d("718109030000001f0300000020")) == .systemInfo(protocolVersion: 3, abilities: 799))
        #expect(KingsmithMessage.parse(d("73500d0018ce496b87d6120000000000d9"))
                == .workoutEvent(number: 0, runId: 1_799_999_000, userId: 1_234_567))
        // Bad checksum is rejected.
        #expect(KingsmithMessage.parse(d("718000f2")) == nil)
    }

    @Test func properties() throws {
        let msg = KingsmithMessage.parse(d("72802801000000040001000500000002003c4008003f000a00000206000000090001000700b4000d00860155"))
        guard case .properties(let raw) = msg else { Issue.record("not properties: \(String(describing: msg))"); return }
        #expect(raw.count == 10)
        let p = DeviceProperties(raw: raw)
        #expect(p.metric)
        #expect(p.errorCode == 0)
        #expect(!p.childLockOn)
        #expect(p.maxSpeed == 18.0)
        #expect(!p.autoStopEnabled)
        #expect(p.autoStopTimeSettable)
        #expect(!p.autoStopTimeEnabled)
        #expect(p.autoStopMinutes == 60)
        #expect(p.soundSupported && p.soundOn && p.lightSupported && p.lightOn)
        #expect(p.foldLockSupported && !p.foldLockOn)
    }
}

@Suite struct SettingsWriteTests {
    @Test func soundAndLightFrames() {
        #expect(KingsmithProtocol.setSound(false) == d("7201030801007f"))
        #expect(KingsmithProtocol.setSound(true) == d("72010308030081"))
        #expect(KingsmithProtocol.setLight(true) == d("720103080c008a"))
        #expect(KingsmithProtocol.setLight(false) == d("72010308040082"))
    }

    @Test func goalProgress() {
        var t = TreadmillData(); t.elapsed = 900; t.distance = 1200; t.calories = 80
        let g = WorkoutGoal(kind: .distance, value: 1000, baseline: 500)
        #expect(g.done(t) == 700)
        #expect(abs(g.progress(t) - 0.7) < 0.001)
        #expect(!g.reached(t))
        t.distance = 1500
        #expect(g.reached(t))
        #expect(WorkoutGoal(kind: .time, value: 600).reached(t))
    }
}

@Suite struct MoreSettingsTests {
    @Test func childLockAndIdleShutdown() {
        #expect(KingsmithProtocol.setChildLock(true) == d("7201030603007f"))
        #expect(KingsmithProtocol.setChildLock(false) == d("7201030600007c"))
        // 60 min: 0xE03C, little endian 3C E0.
        let f = [UInt8](KingsmithProtocol.setIdleShutdown(minutes: 60))
        #expect(Array(f.prefix(6)) == [0x72, 0x01, 0x03, 0x02, 0x3C, 0xE0])
        #expect(f.last == KingsmithProtocol.checksum(f.dropLast()))
        #expect(KingsmithProtocol.setIdleShutdown(minutes: nil) == d("72010302000078"))
    }
}

@Suite struct SleepTests {
    @Test func sleepFrame() {
        #expect(KingsmithProtocol.sleep() == d("7201030a4000c0"))
        #expect(KingsmithProtocol.setMode(.manual) == d("7201030a000080"))
    }

    @Test func modeFromProperty10() {
        // 0x200 at rest (manual, can sleep); 0x240 when the treadmill went to sleep by itself.
        #expect(DeviceProperties(raw: [10: 0x200]).mode == .manual)
        #expect(DeviceProperties(raw: [10: 0x200]).sleepSupported)
        #expect(DeviceProperties(raw: [10: 0x240]).mode == .standby)
        #expect(!DeviceProperties(raw: [10: 0x000]).sleepSupported)
    }
}
