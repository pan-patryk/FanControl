import Foundation

// 24 h of 30 s temperature samples, in an append-only JSONL file.
//
// The store is written from the control loop, not from the UI: the retained history
// must keep filling on days the menu is never opened. The published `tempHistory`
// mirror is only refreshed while something is looking at it.

extension FanViewModel {

    func recordHistoryIfNeeded(now: Date) {
        // At least one valid reading is required; sourced from the control loop's own
        // canonical temperatures, so the feed keeps filling while nothing is on screen.
        guard controlTemps.values.first != nil else { return }
        if let lastTime = lastHistoryRecordTime, now.timeIntervalSince(lastTime) < 30.0 { return }

        let record = TempRecord(
            timestamp: now,
            cpu: controlTemps[.cpu],
            gpu: controlTemps[.gpu],
            battery: controlTemps[.battery],
            fanTargetPercent: highestTargetPercent(from: rawStatus?.fans ?? [])
        )
        historyBuffer.append(record)
        lastHistoryRecordTime = now
        historyStore?.append(record)
        if historyBuffer.count % 60 == 0 { pruneHistory() }
    }

    /// The history graph has one fan-target series. When fans differ, record the
    /// highest SMC target percentage, so the trace stays conservative.
    func highestTargetPercent(from fanList: [FanJSON]) -> Double? {
        fanList.compactMap { FanPercentage.targetPercent(of: $0) }.max()
    }

    func pruneHistory() {
        let cutoff = Date().addingTimeInterval(-historyRetentionInterval)
        let before = historyBuffer.count
        historyBuffer.removeAll { $0.timestamp < cutoff }
        if historyBuffer.count != before { historyStore?.rewrite(historyBuffer) }
    }

    /// Load the file and trim to the retention window.
    func loadHistory() {
        guard let store = historyStore else { return }
        let records = store.load()
        let cutoff = Date().addingTimeInterval(-historyRetentionInterval)
        historyBuffer = records.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        lastHistoryRecordTime = historyBuffer.last?.timestamp
    }

    func cleanHistory(_ records: [TempRecord]) -> [TempRecord] {
        var previousCPU: Double? = nil
        var previousGPU: Double? = nil
        var previousBattery: Double? = nil
        return records.map { record in
            let cpu = Self.cleanHistoricalTemperature(record.cpu, previous: &previousCPU, sensor: .cpu)
            let gpu = Self.cleanHistoricalTemperature(record.gpu, previous: &previousGPU, sensor: .gpu)
            let battery = Self.cleanHistoricalTemperature(record.battery, previous: &previousBattery, sensor: .battery)
            let fan = record.fanTargetPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            return TempRecord(id: record.id, timestamp: record.timestamp, cpu: cpu, gpu: gpu, battery: battery, fanTargetPercent: fan)
        }
    }

    /// Drops non-finite / out-of-bounds / discontinuous values from a stored series,
    /// walking forwards so each candidate is compared with the last *accepted* one.
    static func cleanHistoricalTemperature(_ candidate: Double?, previous: inout Double?, sensor: TemperatureSensor) -> Double? {
        defer { if let value = candidate { previous = value } }
        guard let candidate, candidate.isFinite, SensorGate(sensor: sensor).bounds.contains(candidate) else { return nil }
        if let previous, abs(candidate - previous) > SensorGate.maxPlausibleStep { return nil }
        return candidate
    }
}
