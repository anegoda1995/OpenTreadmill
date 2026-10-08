import SwiftUI
import TreadmillKit

@main
struct OpenTreadmillApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("OpenTreadmill", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.treadmill)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1020, height: 800)
        .commands { TreadmillCommands(treadmill: model.treadmill) }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model.treadmill)
        } label: {
            MenuBarLabel(treadmill: model.treadmill)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keyboard control while walking: the shortcuts work whenever the app is active.
struct TreadmillCommands: Commands {
    @ObservedObject var treadmill: TreadmillManager

    var body: some Commands {
        CommandMenu("Treadmill") {
            Button(treadmill.belt.phase == .running ? "Pause" : "Start or Resume") { treadmill.primaryAction() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!treadmill.isReady || treadmill.isBusy)

            Button("Stop") { treadmill.stopAll() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!treadmill.isReady)

            Divider()

            Button("Faster (+0.1)") { treadmill.nudgeSpeed(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Button("Slower (-0.1)") { treadmill.nudgeSpeed(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Faster (+0.5)") { treadmill.nudgeSpeed(by: 0.5) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Button("Slower (-0.5)") { treadmill.nudgeSpeed(by: -0.5) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
        }
    }
}

/// The menu bar item: the space bar from the app icon, one drawing per state (template images
/// Menu<State>Template.png from assets/menubar-*.svg), and the speed and time while the belt runs.
struct MenuBarLabel: View {
    @ObservedObject var treadmill: TreadmillManager

    var body: some View {
        if treadmill.belt.phase == .running {
            HStack(spacing: 4) {
                glyph("Walking")
                Text("\(Format.speed(treadmill.live.speed)) km/h \u{00B7} \(Format.clock(treadmill.live.elapsed ?? 0))")
            }
        } else {
            glyph(state)
        }
    }

    private var state: String {
        switch treadmill.link {
        case .connected:
            switch treadmill.belt.phase {
            case .running, .starting: return "Walking"
            case .paused: return "Paused"
            case .stopped, .unknown: return "Ready"
            }
        case .asleep: return "Asleep"
        default: return "Searching"
        }
    }

    private func glyph(_ name: String) -> Image {
        guard let image = NSImage(named: "Menu\(name)Template") else { return Image(systemName: "figure.walk") }
        image.isTemplate = true
        return Image(nsImage: image)
    }
}
