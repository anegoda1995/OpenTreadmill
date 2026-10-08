<p align="center">
  <img src="assets/icon.svg" width="128" height="128" alt="OpenTreadmill icon">
</p>

<h1 align="center">OpenTreadmill</h1>

<p align="center">
  Run your KingSmith treadmill from the Mac: live numbers, speed control, programs and history.<br>
  A native macOS app, no account and no cloud.
</p>

<p align="center">
  <a href="https://github.com/anegoda1995/OpenTreadmill/actions/workflows/ci.yml"><img src="https://github.com/anegoda1995/OpenTreadmill/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/anegoda1995/OpenTreadmill/releases/latest"><img src="https://img.shields.io/github/v/release/anegoda1995/OpenTreadmill" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

## Why

A treadmill under a desk is used from the desk. The vendor's app lives on the phone, which is in a pocket or on a
charger while you walk and work. OpenTreadmill puts the numbers and the controls on the screen you are already
looking at, and keeps your workouts on your Mac.

## What it does

- Connects to the treadmill over Bluetooth and shows distance, time, speed, steps, calories, pace, average speed and
  steps per minute, with a live speed chart.
- Start, pause, stop and change the speed from the window, the menu bar or the keyboard.
- Goals by time, distance or calories: the belt stops when the goal is reached.
- Interval programs: six walking templates and your own, with an editor.
- History with daily, monthly and total figures, a sortable table, speed and cadence charts, and a summary image to
  share.
- Treadmill settings: buzzer, marquee light, child lock, idle shutdown.
- Sleep: switches the treadmill off after a stop. It wakes up with its own button or the remote, and the app
  reconnects by itself.
- A speed limit for the app (6 km/h by default) and a second click for big jumps up.
- "Hand over to the phone" frees the treadmill for the vendor's app without stopping the belt.

## Supported treadmills

Other KingSmith treadmills that speak the standard Fitness Machine Service will probably work for live data and
speed control; the KingSmith-specific settings may not. Reports for other models are welcome in the issues.

## Tested on

| | |
| --- | --- |
| Treadmill | KingSmith X218, Bluetooth name `KS-NG-X18F3`, firmware V74.02.26, software V0.0.18, 1 to 18 km/h |
| Mac | MacBook Pro 16-inch (2021), Apple M1 Pro, 16 GB |
| macOS | 15.7.9 (Sequoia) |

Checked on this treadmill: connecting, live data, start, pause, stop, speed changes and the safeguards around
them. Goals, programs, Sleep and the settings switches are newer and not yet tried on it.

## Install

**From a release** (Apple Silicon and Intel, macOS 14 or later):

1. Download `OpenTreadmill-<version>.zip` from [Releases](https://github.com/anegoda1995/OpenTreadmill/releases/latest) and unzip it.
2. In Terminal, run `./install.sh` from the unzipped folder. It copies the app to `/Applications` and starts it.
3. macOS asks for **Bluetooth**. Allow it.

The builds are not notarized, which is why `install.sh` removes the quarantine flag from the app. By hand: move the
app to `/Applications` and open it with right click > Open (on macOS 15: System Settings > Privacy & Security >
Open Anyway).

**From source** (the Command Line Tools are enough, `xcode-select --install`):

```sh
git clone https://github.com/anegoda1995/OpenTreadmill.git
cd OpenTreadmill
make install
```

`make` alone builds `build/OpenTreadmill.app`, `make test` runs the unit tests, `make dist` packs a release zip.

## Use

Turn the treadmill on and start OpenTreadmill: it connects to the first KingSmith treadmill it finds and remembers
it. The treadmill talks to one device at a time, so close the phone app first if it is connected.

| Key | Action |
| --- | --- |
| Space | start, pause, resume |
| Esc | stop |
| Cmd + Up / Cmd + Down | speed +0.1 / -0.1 km/h |
| Shift + Cmd + Up / Down | speed +0.5 / -0.5 km/h |

Space and Esc work while the main window is in front; the Cmd shortcuts work whenever the app is active. The menu bar
item shows speed and time and has the same controls.

## Safety

This app moves a belt you stand on. Use it the way you would use the remote:

- Keep the treadmill's safety key attached. It works without the app.
- Stop and pause go through Bluetooth and take a second or two. The treadmill's own button and remote are faster.
- If the app quits or Bluetooth drops, the belt keeps running at its current speed. Stop it on the treadmill.
- The treadmill refuses some commands while the belt speeds up or slows down. The app waits and retries, so a start
  pressed right after a pause begins once the belt has stopped.

The software comes without any warranty, see the [license](LICENSE).

## How it works

Live data and control use the Bluetooth SIG **Fitness Machine Service** (FTMS): Treadmill Data notifications,
the Control Point for start, pause, stop and target speed, and Fitness Machine Status. KingSmith treadmills also
have their own GATT service, used here for the opening handshake, the settings and the treadmill's run ids.

The control logic follows what the X218 accepts in each phase. For example it refuses Stop while the belt moves, so
the app pauses first and stops once the belt stands still; and after a stop it forgets which device had control, so
the app asks again. A simulated treadmill in the unit tests replays these rules.

OpenTreadmill was written independently for interoperability with hardware its users own. It contains no code,
images or other material from the vendor's apps.

## Privacy

The app talks to the treadmill over Bluetooth and makes no network connections. Workouts, programs and a Bluetooth
log for troubleshooting are stored in `~/Library/Application Support/OpenTreadmill`.

## Uninstall

Run `./uninstall.sh` from the release folder, or `make uninstall` in the source tree. It removes the app and resets
the Bluetooth permission; `./uninstall.sh --purge` also deletes the history and settings.

## Contributing

Pull requests go to the `dev` branch. `main` only changes through a `dev` -> `main` pull request, which is a
release: it gets a `vX.Y.Z` tag, and CI builds the release zip from it.

## License

[GPL-3.0-or-later](LICENSE). You may use, study, share and change the code. If you distribute it, changed or not,
you must do so under the same license and with the source code.

OpenTreadmill is not affiliated with or endorsed by KingSmith. KingSmith, WalkingPad and KS Fit are trademarks of
their owners and are used here only to say which hardware the app works with.
