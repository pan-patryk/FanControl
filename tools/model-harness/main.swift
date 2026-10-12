import Foundation

// MARK: - Model-layer harness
//
// Pure checks over the parts of the app that decide what the fans do: the sensor
// axis, the curve presets, knot sanitising, the history record's derived series and
// the stored-blob compatibility. Foundation-only by design — `run.sh` compiles just
// these four sources plus this file, so a check cannot quietly start depending on
// SwiftUI and stop being runnable.

var failures = 0
func check(_ label: String, _ cond: Bool) {
    if cond {
        print("PASS \(label)")
    } else {
        print("FAIL \(label)")
        failures += 1
    }
}

// MARK: 1 — the Auto sensor is silicon for axis purposes

let hottest = TemperatureSensor.hottest
check("hottest rawValue = Auto", hottest.rawValue == "Auto")
check("hottest domain is silicon 30...110", hottest.domain == 30...110)
check("hottest gate bounds 10...115", SensorGate(sensor: .hottest).bounds == 10...115)
check("battery domain unchanged at 5...60", TemperatureSensor.battery.domain == 5...60)
check("allCases carries Auto exactly once", TemperatureSensor.allCases.filter { $0 == .hottest }.count == 1)

// MARK: 2 — presets: same character per axis, Auto follows the silicon shapes

let autoPresets = FanCurve.presets(for: .hottest)
check("4 presets for Auto", autoPresets.count == 4)
check("Auto presets carry sensor Auto", autoPresets.allSatisfy { $0.sensor == .hottest })
check("balanced for Auto starts 45°C → 10%",
      autoPresets[1].points.first?.x == 45 && autoPresets[1].points.first?.y == 10)
let batteryPresets = FanCurve.presets(for: .battery)
check("balanced for battery starts 15°C → 10%",
      batteryPresets[1].points.first?.x == 15 && batteryPresets[1].points.first?.y == 10)
check("full throttle for battery starts at the axis floor", batteryPresets[3].points.first?.x == 5)
check("Auto presets are already sanitised", autoPresets.allSatisfy { $0.points == $0.sanitized().points })

// MARK: 3 — sampling

check("balanced sample 80°C ≈ 67.5%", abs(autoPresets[1].sample(temp: 80) - 67.5) < 0.01)
check("battery balanced sample 35°C = 45%", abs(batteryPresets[1].sample(temp: 35) - 45) < 0.01)
check("sample clamps below the first knot", autoPresets[1].sample(temp: 10) == autoPresets[1].points.first!.y)
check("sample clamps above the last knot", autoPresets[1].sample(temp: 200) == autoPresets[1].points.last!.y)

// MARK: 4 — sanitising keeps knots legal

var wild = FanCurve(id: "t", name: "t", isBuiltIn: false, sensor: .hottest,
                    points: [CurvePoint(x: 5, y: 200), CurvePoint(x: 300, y: 20)])
wild = wild.sanitized()
check("sanitize clamps speed into 0...100", wild.points[0].y == 100)
check("sanitize pulls knots inside the axis", wild.points[0].x == 30 && wild.points[1].x == 110)

let crossing = FanCurve(id: "t", name: "t", isBuiltIn: false, sensor: .cpu,
                        points: [CurvePoint(x: 60, y: 50), CurvePoint(x: 40, y: 60)]).sanitized()
check("sanitize sorts knots by temperature", crossing.points.map(\.x) == [40, 60])

let crowded = FanCurve(id: "t", name: "t", isBuiltIn: false, sensor: .battery,
                       points: [CurvePoint(x: 58, y: 10), CurvePoint(x: 59, y: 20),
                                CurvePoint(x: 60, y: 30), CurvePoint(x: 61, y: 40)]).sanitized()
check("sanitize keeps the tail inside the axis", (crowded.points.allSatisfy { $0.x <= 60 }))
check("sanitize keeps knots ordered and spaced",
      zip(crowded.points, crowded.points.dropFirst()).allSatisfy { $0.x + 0.5 <= $1.x + 0.0001 })

// Deterministic pseudo-random fuzz: every sanitised curve must satisfy the invariants.
var state: UInt64 = 0x9E3779B97F4A7C15
func next(_ span: Double) -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Double(state >> 11) / Double(UInt64.max >> 11) * span
}
var fuzzOK = true
for _ in 0..<400 {
    let sensor = TemperatureSensor.allCases[Int(next(4))]
    let count = 1 + Int(next(6))
    let curve = FanCurve(id: "f", name: "f", isBuiltIn: false, sensor: sensor,
                         points: (0..<count).map { _ in CurvePoint(x: next(300) - 50, y: next(220) - 60) })
    let clean = curve.sanitized()
    let axis = FanCurve.xDomain(for: sensor)
    if clean.points.count != count { fuzzOK = false }
    if clean.points.contains(where: { !axis.contains($0.x) || $0.y < 0 || $0.y > 100 }) { fuzzOK = false }
    if zip(clean.points, clean.points.dropFirst()).contains(where: { $0.x + 0.5 > $1.x + 0.0001 }) { fuzzOK = false }
}
check("sanitize invariants hold over 400 random curves", fuzzOK)

// MARK: 5 — stored-blob compatibility

let orig = FanCurve(id: "user-abc", name: "My curve", isBuiltIn: false, sensor: .hottest,
                    points: [CurvePoint(x: 40, y: 15), CurvePoint(x: 90, y: 95)])
let data = try! JSONEncoder().encode([orig])
let back = try! JSONDecoder().decode([FanCurve].self, from: data)
check("Auto curve survives JSON round-trip", back.first?.sensor == .hottest && back.first?.id == "user-abc")

let legacyJSON = """
[{"id":"custom","name":"Performance","isBuiltIn":false,"sensor":"GPU","points":[{"id":"11111111-1111-1111-1111-111111111111","x":43.2,"y":19.9},{"id":"22222222-2222-2222-2222-222222222222","x":76.8,"y":99.7}]}]
""".data(using: .utf8)!
let legacy = try! JSONDecoder().decode([FanCurve].self, from: legacyJSON)
check("legacy GPU curve still decodes", legacy.first?.sensor == .gpu && legacy.first?.id == "custom")

// A stored curve whose knots wandered outside today's axis must load, not vanish.
let stray = try! JSONDecoder().decode([FanCurve].self, from: data).first!
check("decoding never drops knots", stray.points.count == 2)

// MARK: 6 — derived history series

check("record Auto = max(CPU, GPU)", TempRecord(cpu: 60, gpu: 55, battery: 30).value(for: .hottest) == 60)
check("record Auto nil when both nil", TempRecord(cpu: nil, gpu: nil, battery: 30).value(for: .hottest) == nil)
check("record Auto = the one live stream", TempRecord(cpu: nil, gpu: 70, battery: nil).value(for: .hottest) == 70)
check("record Auto ignores battery", TempRecord(cpu: nil, gpu: nil, battery: 30).value(for: .hottest) == nil)

// MARK: 7 — identity

check("new curve ids are prefixed", FanCurve.newUserCurveID().hasPrefix("user-"))
check("new curve ids are unique", Set((0..<200).map { _ in FanCurve.newUserCurveID() }).count == 200)

// MARK: 8 — profiles (curve + sensor + response knobs as one bundle)

let factory = FanProfile.factoryDefaults()
check("4 factory profiles", factory.count == 4)
check("factory profiles are marked default", factory.allSatisfy(\.isDefault))
check("factory profile ids are stable",
      factory.map(\.id) == ["default-silent", "default-balanced", "default-performance", "default-full"])
check("Balanced profile carries the balanced knobs",
      factory[1].rise == 6 && factory[1].fall == 3 && factory[1].hysteresis == 5
        && factory[1].minChange == 4 && factory[1].confirmation == 8)
check("Silent profile carries the calm knobs", factory[0].rise == 2 && factory[0].confirmation == 20)
check("Full throttle profile is immediate", factory[3].rise == 100 && factory[3].confirmation == 0)
check("factory profiles point at the built-in shapes",
      zip(factory, [FanCurve.silent, FanCurve.balanced, FanCurve.performance, FanCurve.fullThrottle])
        .allSatisfy { $0.curveID == $1.id })

let profileData = try! JSONEncoder().encode(factory)
let profileBack = try! JSONDecoder().decode([FanProfile].self, from: profileData)
check("profiles survive a JSON round-trip", profileBack.map(\.id) == factory.map(\.id)
    && profileBack[1].sensor == factory[1].sensor)

// A tuned built-in keeps its values across a reload; the factory keeps the name.
var tuned = factory[1]
tuned.rise = 42
tuned.name = "Hacked"
let userProfile = FanProfile(id: "profile-user-1", name: "Mine", isDefault: false,
                             curveID: "user-abc", sensor: .gpu,
                             rise: 9, fall: 9, hysteresis: 0, minChange: 0, confirmation: 0)
let merged = FanProfile.merged(stored: [tuned, userProfile])
check("merge keeps a tuned built-in's values", merged.first(where: { $0.id == "default-balanced" })?.rise == 42)
check("merge restores the factory name", merged.first(where: { $0.id == "default-balanced" })?.name == "Balanced")
check("merge keeps user profiles", merged.contains { !$0.isDefault && $0.name == "Mine" })
check("merge seeds an empty store with all four defaults", FanProfile.merged(stored: []).count == 4)
check("merge drops a retired built-in id", !merged.contains { $0.id == "default-retired" }
    || FanProfile.merged(stored: [FanProfile(id: "default-retired", name: "Gone", isDefault: true,
                                             curveID: "silent", sensor: .cpu,
                                             rise: 1, fall: 1, hysteresis: 1,
                                             minChange: 1, confirmation: 1)])
        .contains { $0.id == "default-retired" })
check("new profile ids are prefixed", FanProfile.newUserProfileID().hasPrefix(FanProfile.newUserProfileIDPrefix))

// MARK: 9 — CommandFilter: the units on the sliders are the units you get
//
// Regression net for the cooling-confirmation bug: the confirmation gates the
// START of cooling, then the slew limiter runs at the configured rate. It used
// to re-arm the clock on every intermediate step, so 3 %/s measured 0.34 %/s.

func runFilter(stepAt: Int, low: Double, high: Double, ticks: Int) -> [Double] {
    var filter = CommandFilter(riseRate: 6, fallRate: 3, hysteresisC: 5,
                               minChangePercent: 4, confirmationSeconds: 8)
    var when = Date(timeIntervalSince1970: 1_000_000)
    var out: [Double] = []
    for i in 0..<ticks {
        out.append(filter.percent(desired: i < stepAt ? low : high, now: when))
        when = when.addingTimeInterval(1)
    }
    return out
}

let falling = runFilter(stepAt: 10, low: 80, high: 60, ticks: 40)
check("cooling waits the 8 s confirmation before the first step", falling[17] == 80)
check("then falls at the configured 3 %/s (77 → 74 → 71 → 68)",
      falling[18] == 77 && falling[19] == 74 && falling[20] == 71 && falling[21] == 68)
check("settles inside the 4 % deadband, at the demand not below it",
      falling[24] <= 62.01 && falling[24] >= 60)
check("cooling never overshoots the demand", (falling.dropFirst(10).min() ?? 0) >= 60)

let rising = runFilter(stepAt: 10, low: 60, high: 80, ticks: 40)
check("a rising demand is not gated by the cooling confirmation", rising[12] >= 76)
check("rise is capped at the configured 6 %/s", rising[11] <= 72.01)

let bypass = runFilter(stepAt: 10, low: 60, high: 100, ticks: 20)
check("a 95 %+ demand bypasses the limiter entirely", bypass[10] == 100)

print(failures == 0 ? "\nALL MODEL CHECKS PASSED" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
