import SwiftUI
import Charts

struct TempHistoryChartView: View, Equatable {
    let summaryLabelWidth: CGFloat = 48
    let summaryColumnWidth: CGFloat = 148

    // Max points actually drawn per series. The 24 h window holds up to ~2880
    // samples; rendering every one makes a single layout pass of this chart
    // expensive, so downsampling caps the mark count.
    static let maxRenderedPoints = 120

    /// Throttle for the hover hit-test (see `updateHoveredTime`).
    @State var lastHoverUpdate: Date? = nil
    static let hoverMinimumInterval: TimeInterval = 1.0 / 20


    // Only the data drives the chart. Excluding the closures/state lets
    // `.equatable()` prune this subtree from the layout pass on polls where the
    // history is unchanged (history records every 30 s; sensors poll every 1 s).
    static func == (lhs: TempHistoryChartView, rhs: TempHistoryChartView) -> Bool {
        lhs.history == rhs.history
            && lhs.compactLayout == rhs.compactLayout
            && lhs.now == rhs.now
    }

    /// Evenly strides the points down to at most `maxRenderedPoints`, always
    /// keeping the last (most recent) sample so "NOW" stays accurate.
    private func downsample(_ pts: [ChartPoint]) -> [ChartPoint] {
        guard pts.count > Self.maxRenderedPoints else { return pts }
        let step = Double(pts.count) / Double(Self.maxRenderedPoints)
        var result: [ChartPoint] = []
        result.reserveCapacity(Self.maxRenderedPoints + 1)
        var cursor = 0.0
        while Int(cursor) < pts.count {
            result.append(pts[Int(cursor)])
            cursor += step
        }
        if let last = pts.last, result.last?.id != last.id {
            result.append(last)
        }
        return result
    }


    /// Which series to draw, and how much room it has.
    ///
    /// These are the view's only inputs: the parent owns the clock (see `now`) and the
    /// history arrives from the control loop, so the chart itself holds no state that
    /// can go stale.
    let history: [TempRecord]
    let compactLayout: Bool

    /// Right edge of the rolling window, supplied by the parent.
    ///
    /// "Now" must be an *input*. Evaluating `Date()` inside `body` and then letting
    /// `.equatable()` prune re-renders on an unchanged history freezes the axis: new
    /// samples walk off the left edge while the right edge stays in the past, so a
    /// live trace looks dead. As an input, a new value forces exactly one re-render
    /// per tick instead of one per poll.
    var now: Date = Date()


    @State var hoveredTime: Date? = nil
    @AppStorage("temperatureHistoryDisplayWindow") var timeWindowRawValue = TimeWindow.twoHours.rawValue
    @AppStorage("showCPUHistory") var showCPUHistory = true
    @AppStorage("showGPUHistory") var showGPUHistory = true
    @AppStorage("showBatteryHistory") var showBatteryHistory = true
    @AppStorage("showFanTargetHistory") var showFanTargetHistory = true

    var body: some View {
        // The graph is a rolling window ending at the present moment, rather
        // than a calendar-day view beginning at midnight.
        let now = self.now
        let windowStart = now.addingTimeInterval(-selectedTimeWindow.interval)
        let displayedSeries = selectedSensors.map(ChartSeries.sensor)
            + (showFanTargetHistory ? [.fanTarget] : [])
        let pointsBySeries: [ChartSeries: [ChartPoint]] = Dictionary(
            uniqueKeysWithValues: displayedSeries.map { series in
                (series, points(for: series, from: windowStart, through: now))
            }
        )
        // Marks and hover hit-testing run against the downsampled set; the range
        // columns above stay on the full history for accuracy (that scan is cheap).
        let sampledBySeries: [ChartSeries: [ChartPoint]] = Dictionary(
            uniqueKeysWithValues: displayedSeries.map { series in
                (series, downsample(pointsBySeries[series] ?? []))
            }
        )
        let allPoints = displayedSeries.flatMap { s in sampledBySeries[s] ?? [] }
        let hoverPoints = hoveredTime.map { time in
            displayedSeries.compactMap { series in
                sampledBySeries[series]?.min { a, b in
                    abs(a.time.timeIntervalSince(time)) < abs(b.time.timeIntervalSince(time))
                }
            }
        } ?? []
        // This is the one values strip for the chart: live values normally,
        // or values at the inspected instant while the pointer is in the graph.
        let inspectionPoints = hoverPoints.isEmpty
            ? displayedSeries.compactMap { pointsBySeries[$0]?.last }
            : hoverPoints
        let chartScaleMaximum = max(
            105.0,
            ceil((allPoints.map(\.value).max() ?? 0.0) / 5.0) * 5.0
        )

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundColor(DS.accent)
                        .font(.system(size: 14, weight: .bold))
                    Text("Temperature & fan target history")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.text)
                }

                Spacer()

                Picker("History duration", selection: $timeWindowRawValue) {
                    ForEach(TimeWindow.allCases) { window in
                        Text(window.label).tag(window.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 112)
                .help(L10n.text("Choose the rolling time range shown in the graph"))
            }

            HStack(spacing: 10) {
                Color.clear.frame(width: summaryLabelWidth, height: 1)
                sensorToggle(.cpu, isOn: $showCPUHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                sensorToggle(.gpu, isOn: $showGPUHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                sensorToggle(.battery, isOn: $showBatteryHistory)
                    .frame(width: summaryColumnWidth, alignment: .leading)
                fanTargetToggle
                    .frame(width: summaryColumnWidth, alignment: .leading)
                Spacer(minLength: 0)
            }

            if selectedSensors.isEmpty && !showFanTargetHistory {
                emptyState(
                    icon: "chart.xyaxis.line",
                    message: "Select one or more series to display their history."
                )
            } else if allPoints.isEmpty {
                emptyState(
                    icon: "chart.xyaxis.line",
                    message: "No temperature data recorded in this time range yet."
                )
            } else {
                HStack(spacing: 10) {
                    Text(hoveredTime == nil ? L10n.text("Now") : timeFormatter.string(from: hoveredTime!))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.secondary)
                        .frame(width: summaryLabelWidth, alignment: .leading)

                    inspectionColumn(for: .sensor(.cpu), in: inspectionPoints)
                    inspectionColumn(for: .sensor(.gpu), in: inspectionPoints)
                    inspectionColumn(for: .sensor(.battery), in: inspectionPoints)
                    inspectionColumn(for: .fanTarget, in: inspectionPoints)
                    
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DS.secondary.opacity(0.3))
                .cornerRadius(6)

                HStack(spacing: 10) {
                    Text("Range")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.secondary)
                        .frame(width: summaryLabelWidth, alignment: .leading)
                    periodRangeColumn(for: .sensor(.cpu), points: pointsBySeries[.sensor(.cpu)])
                    periodRangeColumn(for: .sensor(.gpu), points: pointsBySeries[.sensor(.gpu)])
                    periodRangeColumn(for: .sensor(.battery), points: pointsBySeries[.sensor(.battery)])
                    periodRangeColumn(for: .fanTarget, points: pointsBySeries[.fanTarget])
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.035))
                .cornerRadius(6)

                Text("Shared scale: temperature in °C; blue fan target in % (limited to 100%).")
                    .font(.system(size: 9))
                    .foregroundColor(DS.secondary)

                Chart {
                    ForEach(selectedSensors, id: \.self) { sensor in
                        ForEach(sampledBySeries[.sensor(sensor)] ?? []) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("Temperature", point.value),
                                series: .value("Sensor", sensor.rawValue)
                            )
                            .foregroundStyle(sensorColor(sensor))
                            .interpolationMethod(.monotone)
                        }
                    }

                    if showFanTargetHistory {
                        ForEach(sampledBySeries[.fanTarget] ?? []) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("Fan target", point.value),
                                series: .value("Series", "Fan target")
                            )
                            .foregroundStyle(Color.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2.2))
                            .interpolationMethod(.stepCenter)
                        }
                    }

                    if let hoveredTime {
                        RuleMark(x: .value("Hover Time", hoveredTime))
                            .foregroundStyle(Color.white.opacity(0.25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))

                        ForEach(hoverPoints) { point in
                            PointMark(
                                x: .value("Hover Time", point.time),
                                y: .value("Hover Value", point.value)
                            )
                            .foregroundStyle(seriesColor(point.series))
                            .symbolSize(80)
                        }
                    }
                }
                .chartXScale(domain: windowStart...now)
                .chartYScale(domain: 0.0...chartScaleMaximum)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.white.opacity(0.14))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.8))
                            .foregroundStyle(Color.white.opacity(0.18))
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                            .foregroundStyle(Color.gray)
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .stride(by: 5)) { value in
                        if let temperature = value.as(Double.self) {
                            let roundedTemperature = Int(temperature.rounded())
                            let isMajor = roundedTemperature.isMultiple(of: 10)
                            AxisGridLine(stroke: StrokeStyle(lineWidth: isMajor ? 0.9 : 0.4))
                                .foregroundStyle(Color.white.opacity(isMajor ? 0.18 : 0.08))
                            if isMajor {
                                AxisTick(stroke: StrokeStyle(lineWidth: 0.9))
                                    .foregroundStyle(Color.white.opacity(0.22))
                            AxisValueLabel {
                                Text(String(format: "%.0f", temperature))
                                        .foregroundColor(DS.secondary)
                                        .font(.system(size: 9))
                                }
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { _ in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        updateHoveredTime(at: value.location.x, using: proxy, from: allPoints)
                                    }
                                    .onEnded { _ in
                                        hoveredTime = nil
                                    }
                            )
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    updateHoveredTime(at: location.x, using: proxy, from: allPoints)
                                case .ended:
                                    hoveredTime = nil
                                }
                            }
                    }
                }
                .frame(height: compactLayout ? 160 : 240)
            }
        }
        .padding(compactLayout ? 12 : 16)
        .background(DS.cardFill)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DS.secondary.opacity(0.3), lineWidth: 1)
        )
        .onChange(of: displayedSeries) { _ in
            hoveredTime = nil
        }
        .onChange(of: timeWindowRawValue) { _ in
            hoveredTime = nil
        }
    }

}
