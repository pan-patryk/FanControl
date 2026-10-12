import SwiftUI
import Charts

// Data shaping for the 24 h history chart: which series the graph can draw, the
// per-sensor presentation, and the functions that turn `[TempRecord]` into
// downsampled `ChartPoint`s. Pure functions of the input — no view state, no layout —
// so the sampling and domain choices are readable on their own.

extension TempHistoryChartView {

    enum ChartSeries: Hashable {
        case sensor(TemperatureSensor)
        case fanTarget
    }

    enum TimeWindow: String, CaseIterable, Identifiable {
        case thirtyMinutes
        case oneHour
        case twoHours
        case twelveHours
        case twentyFourHours

        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .twoHours: return 2 * 60 * 60
            case .twelveHours: return 12 * 60 * 60
            case .twentyFourHours: return 24 * 60 * 60
            }
        }

        var label: String {
            switch self {
            case .thirtyMinutes: return L10n.text("Last 30 min")
            case .oneHour: return L10n.text("Last hour")
            case .twoHours: return L10n.text("Last 2 hours")
            case .twelveHours: return L10n.text("Last 12 hours")
            case .twentyFourHours: return L10n.text("Last 24 hours")
            }
        }
    }



    struct ChartPoint: Identifiable {
        let id: String
        let series: ChartSeries
        let time: Date
        let value: Double
    }

    var selectedTimeWindow: TimeWindow {
        TimeWindow(rawValue: timeWindowRawValue) ?? .twoHours
    }

    var selectedSensors: [TemperatureSensor] {
        var sensors: [TemperatureSensor] = []
        if showCPUHistory { sensors.append(.cpu) }
        if showGPUHistory { sensors.append(.gpu) }
        if showBatteryHistory { sensors.append(.battery) }
        return sensors
    }

    var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            selectedTimeWindow == .twentyFourHours ? "MMM d HH:mm" : "HH:mm"
        )
        return formatter
    }

    func sensorName(_ sensor: TemperatureSensor) -> String {
        switch sensor {
        case .cpu: return L10n.text("CPU")
        case .gpu: return L10n.text("GPU")
        case .battery: return L10n.text("Battery")
        case .hottest: return L10n.text("Auto")
        }
    }

    func sensorColor(_ sensor: TemperatureSensor) -> Color {
        switch sensor {
        case .cpu: return DS.warn
        case .gpu: return .purple
        case .battery: return DS.fan
        case .hottest: return DS.accent
        }
    }

    func sensorIcon(_ sensor: TemperatureSensor) -> String {
        switch sensor {
        case .cpu: return "cpu"
        case .gpu: return "gauge.with.needle"
        case .battery: return "battery.100.bolt"
        case .hottest: return "flame.fill"
        }
    }

    func seriesName(_ series: ChartSeries) -> String {
        switch series {
        case .sensor(let sensor): return sensorName(sensor)
        case .fanTarget: return L10n.text("Fan target")
        }
    }

    func seriesColor(_ series: ChartSeries) -> Color {
        switch series {
        case .sensor(let sensor): return sensorColor(sensor)
        case .fanTarget: return .cyan
        }
    }

    func value(for sensor: TemperatureSensor, in record: TempRecord) -> Double? {
        switch sensor {
        case .cpu: return record.cpu
        case .gpu: return record.gpu
        case .battery: return record.battery
        case .hottest: return record.value(for: .hottest)
        }
    }

    func points(
        for sensor: TemperatureSensor,
        from windowStart: Date,
        through now: Date
    ) -> [ChartPoint] {
        history.compactMap { record in
            guard record.timestamp >= windowStart,
                  record.timestamp <= now,
                  let temperature = value(for: sensor, in: record) else {
                return nil
            }
            return ChartPoint(
                id: "\(record.id.uuidString)-\(sensor.rawValue)",
                series: .sensor(sensor),
                time: record.timestamp,
                value: temperature
            )
        }
    }

    func fanTargetPoints(from windowStart: Date, through now: Date) -> [ChartPoint] {
        history.compactMap { record in
            guard record.timestamp >= windowStart,
                  record.timestamp <= now,
                  let targetPercent = record.fanTargetPercent,
                  (0.0...100.0).contains(targetPercent) else {
                return nil
            }
            return ChartPoint(
                id: "\(record.id.uuidString)-fan-target",
                series: .fanTarget,
                time: record.timestamp,
                value: targetPercent
            )
        }
    }

    func points(
        for series: ChartSeries,
        from windowStart: Date,
        through now: Date
    ) -> [ChartPoint] {
        switch series {
        case .sensor(let sensor):
            return points(for: sensor, from: windowStart, through: now)
        case .fanTarget:
            return fanTargetPoints(from: windowStart, through: now)
        }
    }
}
