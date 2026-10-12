import SwiftUI
import Charts

/// One sensor's 24 h temperature history as a minimal line chart with its own
/// color and its own temperature scale, plus hover readout.
///
/// The decimated point set is computed **once per render** and threaded through the
/// body. A computed property would be re-evaluated at every read — the count check,
/// the max label, the chart marks and the y-domain each take a pass — so a 2 880-record
/// history would be scanned four times per chart per second across the three charts in
/// the "Sensors" section. The view is also `Equatable` so the panel's per-second polls
/// prune it when the history hasn't grown.
struct SensorHistoryChart: View, Equatable {
    var history: [TempRecord]
    var sensor: String
    var color: Color
    var value: KeyPath<TempRecord, Double?>

    @State private var hoverIndex: Int? = nil
    @State private var lastHoverUpdate: Date? = nil
    private static let hoverMinimumInterval: TimeInterval = 1.0 / 20

    struct Point: Identifiable {
        let id: Int
        let t: Date
        var v: Double
    }

    static func == (lhs: SensorHistoryChart, rhs: SensorHistoryChart) -> Bool {
        lhs.history == rhs.history && lhs.sensor == rhs.sensor
    }

    /// 5-minute max decimation: ~288 points over 24 h.
    static func points(from history: [TempRecord], value: KeyPath<TempRecord, Double?>,
                       now: Date) -> [Point] {
        guard let first = history.first else { return [] }
        let t0 = first.timestamp
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let bucket = 300.0
        var best: [Int: Point] = [:]
        for record in history where record.timestamp >= cutoff {
            guard let v = record[keyPath: value] else { continue }
            let k = Int(record.timestamp.timeIntervalSince(t0) / bucket)
            var point = best[k] ?? Point(id: k, t: t0.addingTimeInterval(Double(k) * bucket), v: v)
            if v > point.v { point.v = v }
            best[k] = point
        }
        return best.keys.sorted().compactMap { best[$0] }
    }

    /// Own scale per sensor: battery sits near 30° while silicon hits 90°,
    /// so a shared axis made each line unreadable.
    static func yDomain(for points: [Point]) -> ClosedRange<Double> {
        guard let lo = points.map(\.v).min(), let hi = points.map(\.v).max() else { return 0...100 }
        let pad = max((hi - lo) * 0.15, 5)
        return max(0, lo - pad)...(hi + pad)
    }

    var body: some View {
        let points = Self.points(from: history, value: value, now: Date())
        if points.count < 2 {
            HStack {
                Text(sensor).font(DS.mono(10)).foregroundColor(DS.tertiary)
                Spacer()
                Text("collecting…").font(DS.mono(10)).foregroundColor(DS.tertiary)
            }
            .frame(height: 58)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(sensor).font(DS.mono(10)).foregroundColor(DS.secondary)
                    Spacer()
                    if let hi = points.map(\.v).max() {
                        Text("max \(Int(hi.rounded()))°").font(DS.mono(10)).foregroundColor(color)
                    }
                }
                chart(points: points)
            }
        }
    }

    private func chart(points: [Point]) -> some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Temp", p.v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
            }
            if let h = hoverIndex, h < points.count {
                let p = points[h]
                RuleMark(x: .value("Time", p.t))
                    .foregroundStyle(.white.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", p.t), y: .value("Temp", p.v))
                    .foregroundStyle(color)
                    .symbolSize(18)
                    .annotation(position: .top, spacing: 2) {
                        Text("\(Int(p.v.rounded()))°")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    }
            }
        }
        .chartYScale(domain: Self.yDomain(for: points))
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 8)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            // Rate-limited and diffed: hover fires at the pointer's
                            // report rate, and each event is a full scan plus a layout
                            // pass.
                            let now = Date()
                            if let last = lastHoverUpdate, now.timeIntervalSince(last) < Self.hoverMinimumInterval { return }
                            lastHoverUpdate = now
                            let origin = geo[proxy.plotAreaFrame].origin
                            guard let t: Date = proxy.value(atX: pt.x - origin.x) else { return }
                            let match = points.min(by: {
                                abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t))
                            })?.id
                            if match != hoverIndex { hoverIndex = match }
                        case .ended:
                            if hoverIndex != nil { hoverIndex = nil }
                        }
                    }
            }
        }
        .frame(height: 58)
    }
}
