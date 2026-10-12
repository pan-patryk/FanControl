# FanCurve

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-orange) ![License: MIT](https://img.shields.io/badge/license-MIT-green) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-tested-success)

A macOS menu-bar fan controller with an editable temperature → fan-speed curve.

macOS decides fan speed through `thermalmonitord`'s thresholds, which are hidden
and not yours to tune. FanCurve reads the SMC's temperatures and hands the fans
to a curve *you* draw: the hotter the sensor gets, the higher along the curve
the fans go — with rate limits, hysteresis and confirmation so they never
audibly hunt for a target. Everything lives in the menu bar; a full settings
window exists for when you want the graph bigger.

## Requirements

- macOS 13.0 or later.
- A Mac whose fans are driven by the Apple SMC (any Mac laptop or desktop).
- **Apple Silicon is the developed and tested path** (M-series Macs; exercised
  on real Apple Silicon hardware). Intel Macs are supported in code —
  they use a different forced-mode mechanism, the `FS!` bitmask — but that path
  has not been re-verified on Intel hardware.
- Reading sensors needs no privileges. Writing them needs the one-time admin
  install described below.

## Features

- **Two control modes.** *macOS* leaves the fans to `thermalmonitord` (the app
  is then a passive reader and dashboard). *Curve* hands every fan the user has
  not pinned to the XY curve.
- **Editable curve.** Drag knots, tap empty space to add one, right-click to
  delete. Edits land in an unsaved draft that the editor and the engine sample
  live; a small green tick and red cross appear beside the profile selector —
  the tick saves, the cross discards. Four built-in shapes (Silent / Balanced /
  Performance / Full throttle) are re-derived for whichever sensor the curve
  samples — never stored — and saving a modified shape forks it into a new
  named entry, so editing a preset can never overwrite anything. *Start with*
  chooses which curve the app opens on (default *last used*, so a restart
  never changes your setup).
- **Profiles.** One named bundle of curve + sensor + the five response knobs.
  This is the only selector in the editor: the profile menu selects, creates,
  names and removes, and a saved curve is reached through the profile that
  points at it. Built-in profiles absorb the tuning you do while one is
  selected, and *Restore default profiles* puts them back.
- **Sensor choice.** *Auto* (default) follows the hotter of the two validated
  load streams (CPU, GPU) — the app-side equivalent of how macOS blends sensors
  into one fan decision. CPU, GPU and Battery are available individually, each
  with its own temperature axis (battery runs on a 5–60 °C axis, not the
  30–110 °C silicon one).
- **Asymmetric fan response.** Independently configurable rise and fall rates
  (defaults 6 %/s up, 3 %/s down), cooling hysteresis (5 °C), a target deadband
  (4 %) and an 8 s cooling confirmation, so fans never flutter around a target.
  A demand of 95 % or more bypasses the limits immediately — thermal
  protection comes first. Below 0.5 % demand the fans are handed back to macOS.
- **On-battery derating.** When the machine is drawing from the battery the
  curve demand is multiplied by 0.75 (toggleable).
- **Per-fan override.** Pin any fan to a speed, or the whole set with one
  slider or the 20/40/50/80/100 % buttons. "Sync all fans together" applies
  every user command to every fan. Pins are the app's own state and survive
  relaunch *and* sleep.
- **24 h of history.** Samples every 30 s into an append-only JSONL file;
  per-sensor charts with their own scales, a fan-target series, rolling time
  windows (30 min → 24 h) and a hover readout.
- **Sleep/wake survival.** Sleep hands the SMC back to macOS and flushes state;
  on wake the sensor caches, gates, command filter and write bookkeeping are
  reset, and pinned fans are re-armed at their remembered speeds.
- **Menu-bar readout.** The tray icon shows who owns the fans; an optional live
  RPM number sits beside it. A warning glyph means reads still work but every
  command is refused — the curve is armed and cannot write.
- **Quality-of-life.** Start at login, menu-bar-only (accessory) mode, a
  single-instance guard, notification on engage/disengage (rate-limited, only
  for demands ≥ 50 %), and a settings window that costs nothing while closed.

## Install

### From a release

1. Download `FanCurve.dmg` from the project's [Releases](../../releases) page.
2. Open it and drag **FanCurve** into `/Applications`.
3. `open /Applications/FanCurve.app` — a fan icon appears in the menu bar.

### First run

Click the tray icon. Until you install the control service, the panel shows a
**Fan control not installed** card: readings work, commands don't.

Press **Install** (or **Install Control Service…** in the settings window). It
asks for your admin password **once**, registers a small root daemon
(`/Library/fancurve/fancurve-helper`) via launchd, and never asks again — the
daemon lives outside the app bundle, so rebuilding or reinstalling the app
never breaks it.

The tray icon tells you who owns the fans:

| Icon | Meaning |
| --- | --- |
| fan blades | macOS owns the fans (mode: *macOS*, or curve armed and idle) |
| curve glyph | the curve engine is commanding the fans |
| ⚠ warning | no privileged channel — reads work, every command is refused |

**Switching back to *macOS*** in the mode picker hands the fans back to macOS at
any time. Quitting releases every override too, and so does sleep until the
curve re-arms.

> Deleting the app does **not** remove the root privilege it installed — the
> daemon lives outside the bundle on purpose. Use the uninstaller (below) to
> remove it cleanly.

## Using it

### The menu-bar panel

The status item *is* the app. The panel is an accordion:

- **Header** — who has control, per-fan live RPM, CPU/GPU/BAT temperatures,
  and the power-source caption. The header is a readout, not a button.
- **Sensors (24 h)** — three mini charts, one per sensor, each with its own
  temperature scale.
- **Fan control** — the macOS/Curve mode picker, the curve editor (while Curve
  is selected), and the pin summary.
- **Fans** — per-fan RPM sliders, the sync toggle, the all-fans slider and the
  percentage buttons.
- **Tuning** — the five response knobs and the presets (only shown while
  something is commanding).
- **Settings** — start at login, accessory mode, menu-bar RPM readout,
  *Start with*, *Restore default profiles*, and the build stamp.
- **Action row** — *Quit*.

The panel is a real window, not a classic menu: sliders stay draggable and no
action dismisses it — only clicking outside (or Escape) does.

### The curve editor

The XY plot: temperature (°C) on the x-axis, fan speed (%) on the y-axis.

- **Drag** a knot to move it.
- **Tap** empty space to add a knot (tapping near an existing knot nudges it).
- **Right-click** a knot to delete it.
- **Knot chips** below the plot show every knot; the × removes it.
- The **orange dot** is where the machine sits on the curve right now.
- The **Profile menu** at the top is the only selector: *No profile*, the four
  built-ins, your saved profiles, *New profile…* (names inline) and *Remove
  profile* (only for profiles you made).
- The **Mode row** picks what the curve samples: *Auto* (hotter of CPU/GPU),
  CPU, GPU or Battery. Switching rescales a saved curve into the new axis so
  the shape you drew survives; built-ins re-derive themselves.
- **Save or discard.** While the curve differs from its saved state, two
  small buttons appear beside the profile selector: a green tick (save — into
  the profile's curve, or as a new named entry forked from a built-in shape)
  and a red cross (discard — back to the saved status). Switching profile or
  sampling sensor rejects an unsaved draft; creating a profile commits it
  first.

### Tuning

Five knobs bound to one pipeline, so a slider always means the same thing:

| Knob | Meaning | Default |
| --- | --- | --- |
| Rise rate | fastest commanded climb, % of range per second | 6 %/s |
| Fall rate | fastest commanded descent | 3 %/s |
| Hysteresis | °C a falling temperature must give back | 5 °C |
| Min change | smallest commanded change worth writing | 4 % |
| Confirmation | seconds a lower demand must hold before the fans come down | 8 s |

The four presets — **Calm, Balanced, Aggressive, Immediate** — collapse all
five into one tap. They change nothing else: no engine switch, no SMC write.
Above 95 % demand the limits are bypassed entirely.

### Fans

- **Auto / Manual** per fan. Switching to Manual *holds the fan where it is*
  rather than dropping it to its minimum.
- **Sliders** apply on release, not per drag tick.
- **Min / 20 % / 50 % / 80 % / Max** presets per fan.
- **Sync all fans together** — every user command applies to all fans.
- **All-fans slider** — one value across the whole set; the button row is a
  shortcut for 20/40/50/80/100 %.
- Pinned fans are highlighted and labelled *pinned*; **Auto** releases a pin.

### The settings window

Reachable when FanCurve is an ordinary app: turn off *Run in accessory mode*
in the panel's Settings section, then use the app menu's *Settings…* (⌘,).
It carries the same
dashboard, bigger: the 24 h history chart with rolling windows, series toggles
and hover inspection; per-fan cards with animated fan indicators and the full
slider set; the curve editor; the response settings; *Start with*; *Restore
default profiles*; start at login.

### Notifications

The app posts a banner when the curve engages with a demand of 50 % or more
and when the demand goes away and the fans are handed back to macOS. Both are
rate-limited (120 s cooldown) so a demand hovering at the boundary can't buzz
all afternoon. macOS asks for notification permission once at first launch.

## How it works

### The control pipeline

Every tick (1 Hz while something can command; 5 s in passive macOS mode):

1. **Read** the SMC in-process — fan geometry, speeds and one temperature per
   stream. Absent keys and fan geometry are cached, with a reprobe interval, so
   the 1 Hz loop costs a handful of kernel calls, not seventy.
2. **Validate** each temperature in a per-sensor gate. Rises are trusted
   immediately; drop-outs (a sensor falling off the bus reads `0`) are held at
   the last good value and confirmed twice before they are believed. A
   physically impossible reading never reaches the controller.
3. **Sample the curve** at the validated temperature, then apply the on-battery
   derate if the machine is on battery power.
4. **Limit the command** through the four-stage filter: temperature
   hysteresis → demand deadband + cooling confirmation → time-based slew rate
   → emergency bypass (≥ 95 %).
5. **Write** through the privileged channel, but only values that actually
   moved: an identical `F0Tg` write is skipped, so an idle curve costs no SMC
   traffic.
6. **Mirror to the UI** — and only while a panel or window is actually
   visible, and only on a real difference. The control loop never reads a
   published mirror; it samples canonical state, so it commands correctly with
   nothing on screen.

On Apple Silicon, taking a fan away from `thermalmonitord` is a bounded
handshake: the per-fan mode key is written directly when the firmware allows
it, otherwise the `Ftst` test key is raised and the mode write retried while
`thermalmonitord` yields. Everything is bounded by wall clock, because it runs
on the daemon's XPC delivery queue.

### The privilege model

Reading the SMC needs no privileges; writing it does. Two channels, exactly
one live at a time:

1. **The root daemon** (recommended, the default): a launchd job installed
   once from the app bundle into `/Library/fancurve`, talking XPC over a Mach
   service. `KeepAlive` + a 2 s `ThrottleInterval` keep restarts fast, and no
   stdout/stderr files are created — a world-readable thermal log would leak
   your activity.
2. **The bundled setuid helper**: the fallback, used only when the daemon is
   not live, so the two channels can never be half-configured at the same
   time. The setup card offers both.

The daemon authenticates every client by **code signature**, never by path:
it resolves the peer's `SecCode` from the audit token the XPC layer attached
to the connection, checks dynamic validity (rejecting unsigned, tampered and
library-injected processes), and requires the app's signing identifier plus
its team identifier. Ad-hoc signed builds (any local rebuild) are accepted and
their cdhash logged; `strictClientCdHashes` in the shared protocol file can
pin one for development. The daemon offers only the three operations that
require root — SMC writes — so the root attack surface is three validated
integer arguments.

No TCC privacy permission is involved: the app requests no screen recording,
accessibility, or other protected access. All state stays on the machine —
settings in the app's `UserDefaults` domain, history in
`~/Library/Application Support/FanCurve/history.jsonl`.

## Safety and failure behaviour

- **A dead sensor can't command the fans.** A sensor that leaves its plausible
  range or makes a large downward jump is held and confirmed twice; `0` is
  never taken as a real temperature.
- **Pins are the app's own state.** The SMC's forced-mode byte is treated as
  an output, never as evidence of intent — every engine-driven fan is in
  forced mode by definition, so reading it as input would claim the user
  pinned fans they never touched.
- **Sleep is safe.** The SMC keeps a forced mode and target across sleep, so
  sleep hands every fan back to macOS first (pinned speeds are remembered and
  re-armed on wake). A run-loop timer can't fire while the process is
  suspended, so the first post-wake tick is the wake detector —
  `NSWorkspace.didWake` alone is not enough, because it isn't delivered on
  dark wakes.
- **Quit is safe.** `applicationShouldTerminate` releases every override
  without blocking the main thread before the process exits.
- **A wedged read can't freeze the loop** — the in-flight guard re-arms after
  5 s and the next tick retries.
- **History can fail quietly.** A full disk or a revoked permission turns
  recording off for that write instead of terminating the app from inside the
  monitoring loop.

## Uninstall

```bash
sudo ./tools/uninstall.sh                # daemon + setuid helper + login item + app + state
sudo ./tools/uninstall.sh --privileges-only   # drop the root access, keep app and settings
```

It removes the daemon, its launchd job, any stray setuid bit, the login item,
the app and all saved state, and prints the commands to verify the result.

## Build from source

### The script path (recommended)

```bash
./build.sh        # app + helper, universal, then FanCurve.dmg (FanCurve.zip as fallback)
```

`build.sh` compiles both binaries with `swiftc` directly — no Xcode project is
required, only the Xcode command line tools. It stitches the per-architecture
slices with `lipo`, writes `Info.plist`, derives the icon from `AppIcon.png`,
copies the localization table, and signs **ad-hoc** — so **no Apple Developer
account is needed to build and use it locally**. To sign releases with your own
Developer ID instead, override the identity and register its team identifier
(the control daemon refuses any client it cannot vouch for):

```bash
SIGNING_IDENTITY="Developer ID Application: You (TEAMID)" ./build.sh
```

and add `TEAMID` to `allowedTeamIdentifiers` in
`Shared/FanCurveHelperProtocol.swift`.

Defaults you can override:

```bash
ARCHS="arm64" ./build.sh                        # single-architecture build
APP_VERSION=1.0.0 ./build.sh                    # bundle version + DMG volume name
SIGNING_IDENTITY="Developer ID Application: You (TEAMID)" ./build.sh   # your own signing identity
```

`./run.sh` does the whole dev cycle: stop running copies, build, install to
`/Applications`, launch.

### The Xcode path

If you prefer the IDE, generate a project from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

`project.yml` is the source of truth; the generated project is gitignored.

### Why the build is strict

The file lists for both targets live in `sources.sh`, and the build **hard
stops** if the bundle identifier, helper identifier, or version disagree
between `build.sh`, `sources.sh` and `project.yml`. A disagreement there is
silent — an app reading a different `UserDefaults` domain just looks like it
lost the user's settings — so the build refuses instead of shipping the drift.

## Development and diagnostics

```bash
./tools/typecheck.sh                 # app + helper, arm64; no codegen/signing/packaging
./tools/model-harness/run.sh         # curve sampling, knot sanitising, sensor axis,
                                     # limiter rate + confirmation semantics, profiles
python3 tools/strings-audit/audit.py # localization table; fails on dead keys
bash -n tools/uninstall.sh           # uninstaller still parses
```

`tools/model-harness/run.sh` is the regression net for the decision logic:
51 checks over curve sampling and sanitising (including a 400-curve fuzz),
stored-blob compatibility, profile merging, and the limiter's rate/confirmation
semantics — the regression that previously made "3 %/s" measure as 0.34 %/s is
a named check in there.

`tools/thermal-load/` builds a bounded CPU/Metal GPU load generator for
exercising the response filter under real heat:

```bash
cd tools/thermal-load && ./build.sh && ./thermal-load
```

### The helper CLI

The daemon binary is also a command-line tool (reads need no privilege):

```bash
FanCurve.app/Contents/MacOS/fancurve-helper get     # JSON snapshot: fans + temperatures
FanCurve.app/Contents/MacOS/fancurve-helper keys    # raw SMC key metadata (decoding self-check)
FanCurve.app/Contents/MacOS/fancurve-helper reset   # all fans → automatic (needs root)
FanCurve.app/Contents/MacOS/fancurve-helper set <fanId> <0|1> [rpm]   # needs root
```

`keys` is the diagnostic the decoding assumptions rest on: it prints the type,
size and bytes the firmware reports for any key, so a new machine can be
sanity-checked without a debugger.

### Debugging

Set `FANCURVE_DEBUG=1` before launching to trace the control loop on stderr:
every commanded percentage, every write and every reason a write was skipped.
The loop is silent by design in normal use, which makes a "the fans didn't
move" report impossible to diagnose without it.

```bash
FANCURVE_DEBUG=1 /Applications/FanCurve.app/Contents/MacOS/FanCurve
```

## Project layout

| Path | Contents |
| --- | --- |
| `Core/` | `SMC.swift` (AppleSMC IOKit transport, wire structures), `SMC+Values.swift` (register decoding), `SMC+FanOwnership.swift` (claim/release per fan), `SMC+Unlock.swift` (Apple Silicon ownership handshake), `SensorGate.swift` (one validated temperature stream), `CommandFilter.swift` (rate limits, hysteresis, confirmation, bypass), `HistoryStore.swift` (append-only JSONL), `SystemStatusReader.swift` (in-process sensor read + key cache), `FanPercentage.swift`, `Localization.swift` (`L10n`) |
| `Models/` | `FanCurve.swift` (knots, `sample()`, shapes, `sanitized()`), `FanProfile.swift`, `TemperatureSensor.swift` (CPU/GPU/Battery/Auto + per-sensor axis), `TempRecord.swift`, `FanJSON.swift`, `FanResponsePreset.swift`, `MenuBarLabelModel.swift` |
| `ViewModels/` | `FanViewModel.swift` — all state, `Keys`, and the lifecycle. Behaviour is in extensions: `+Readout`, `+Polling`, `+ControlService`, `+FanCommands`, `+ControlLoop`, `+SleepWake`, `+Curves`, `+Profiles`, `+History`, `+AppLifecycle` |
| `Views/` | `MenuBarView.swift` (the panel) + `FanSliders.swift`, `CurveEditorView.swift` + `CurveLineChart.swift` + `CurveEditorPickers.swift`, `ContentView.swift` (settings window), `TempHistoryChartView.swift` + `+Data` + `+Chrome`, `SensorHistoryChart.swift`, `FanRow.swift`, `FanResponseSettingsView.swift`, `StartWithCurvePicker.swift`, `RestoreDefaultProfiles.swift`, `SpinningFanView.swift`, `TerminalStyle.swift` (design tokens, `Gauge`) |
| `App/` | `FanCurveApp.swift` (accessory activation, `MenuBarExtra`, `Settings` scene), `Info.plist`, `AppIcon.icns` |
| `Helper/` | `main.swift` (XPC daemon + CLI), `fancurve-helper.plist` (launchd template) |
| `Shared/` | `FanCurveHelperProtocol.swift` — compiled into both sides so the XPC interfaces can't drift; also the trusted identifiers and the install script |
| `Localization/en.lproj/` | the string table (English; the key *is* the display text) |
| `tools/` | `typecheck.sh`, `model-harness/`, `strings-audit/`, `thermal-load/`, `uninstall.sh` |

## Localization

English is the only shipped locale, through the standard
`Localizable.strings` table. To add a language: drop a
`<lang>.lproj/Localizable.strings` into `Localization/` and add the locale to
`CFBundleLocalizations` in `build.sh`. Note that most panel strings are
SwiftUI literals resolved against the same table at runtime, so a real second
locale also needs a `genstrings` pass over `Views/` — the string audit lists
exactly which literals that pass would have to cover.

## Contributing

Issues and pull requests are welcome. Please:

- keep `./tools/model-harness/run.sh` green for any change that touches the
  decision logic (curve, gate, filter, profiles);
- run `./tools/typecheck.sh` and the strings audit before opening a PR;
- keep single-authority rules intact — one writer per piece of state, one
  conversion per unit, one validation per reading. The code comments document
  each of these; a PR that adds a second writer usually looks like a bug that
  took weeks to reproduce.

## License

MIT — see [LICENSE](LICENSE).
