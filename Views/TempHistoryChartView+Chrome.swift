import SwiftUI
import Charts

// Non-plot chrome around the history chart: the series toggles, the empty-state card,
// and the hover inspection columns. Split out of the main file because the plot itself
// is one long `body` and these are the small reusable pieces it calls.

extension TempHistoryChartView {

    func sensorToggle(_ sensor: TemperatureSensor, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(sensorName(sensor), systemImage: sensorIcon(sensor))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(sensorColor(sensor))
        }
        .toggleStyle(CheckboxToggleStyle())
        .help(L10n.format("Show %@ temperature in the graph", sensorName(sensor)))
    }

    var fanTargetToggle: some View {
        Toggle(isOn: $showFanTargetHistory) {
            Label("Fan target", systemImage: "fanblades")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.accent)
        }
        .toggleStyle(CheckboxToggleStyle())
        .help(L10n.text("Show the highest requested fan speed as a percentage"))
    }

    func emptyState(icon: String, message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.gray.opacity(0.5))
            Text(L10n.text(message))
                .font(.system(size: 12))
                .foregroundColor(DS.secondary)
        }
        .frame(height: compactLayout ? 56 : 72)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.15))
        .cornerRadius(8)
    }

    func inspectionValue(_ point: ChartPoint) -> some View {
        HStack(spacing: 4) {
            Text(seriesName(point.series))
                .foregroundColor(seriesColor(point.series))
            Text(
                point.series == .fanTarget
                    ? String(format: "%.1f%%", point.value)
                    : String(format: "%.1f°C", point.value)
            )
            .fontWeight(.bold)
            .foregroundColor(DS.text)
        }
        .font(.system(size: 10, weight: .medium))
    }

    func inspectionColumn(for series: ChartSeries, in points: [ChartPoint]) -> some View {
        Group {
            if let point = points.first(where: { $0.series == series }) {
                inspectionValue(point)
            } else {
                Color.clear
            }
        }
        .frame(width: summaryColumnWidth, alignment: .leading)
    }

    func periodRangeColumn(for series: ChartSeries, points: [ChartPoint]?) -> some View {
        Group {
            if let points, !points.isEmpty {
                periodRange(series: series, points: points)
            } else {
                Color.clear
            }
        }
        .frame(width: summaryColumnWidth, alignment: .leading)
    }

    func periodRange(series: ChartSeries, points: [ChartPoint]) -> some View {
        let minimum = points.map(\.value).min() ?? 0
        let maximum = points.map(\.value).max() ?? 0
        let unit = series == .fanTarget ? "%" : "°C"

        return HStack(spacing: 4) {
            Text(seriesName(series))
                .foregroundColor(seriesColor(series))
            Text(String(format: "%.1f–%.1f%@", minimum, maximum, unit))
                .fontWeight(.semibold)
                .foregroundColor(DS.text)
        }
        .font(.system(size: 9, weight: .medium))
    }

    func updateHoveredTime(
        at xPosition: CGFloat,
        using proxy: ChartProxy,
        from points: [ChartPoint]
    ) {
        // `onContinuousHover` fires at the pointer's report rate (up to 125 Hz on a
        // ProMotion display). A full linear scan of every visible point, assigned
        // unconditionally, means resting the cursor on the chart costs an O(n) search
        // plus a layout pass per event. So: rate-limit to 20 Hz and assign only when
        // the answer actually changed.
        let now = Date()
        if let last = lastHoverUpdate, now.timeIntervalSince(last) < Self.hoverMinimumInterval { return }
        lastHoverUpdate = now

        guard let date: Date = proxy.value(atX: xPosition) else { return }
        // `points` concatenates several series, so it is not globally sorted — a
        // linear nearest-time scan is the correct (and, at 20 Hz, cheap) search.
        let match = points.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }?.time
        if match != hoveredTime { hoveredTime = match }
    }
}
