import Foundation

public struct TempRecord: Identifiable, Codable, Equatable {
    public var id: UUID
    public let timestamp: Date
    public let cpu: Double?
    public let gpu: Double?
    public let battery: Double?
    public let fanTargetPercent: Double?
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cpu: Double?,
        gpu: Double?,
        battery: Double?,
        fanTargetPercent: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.fanTargetPercent = fanTargetPercent
    }

    /// Convenience accessor so callers don't re-write the same switch (used by the
    /// 24 h summaries and the history chart).
    func value(for sensor: TemperatureSensor) -> Double? {
        switch sensor {
        case .cpu: return cpu
        case .gpu: return gpu
        case .battery: return battery
        // Auto is derived, never stored: the hotter of the two load sensors in the
        // same record, so the 24 h chart's Auto series and the engine agree.
        case .hottest: return [cpu, gpu].compactMap { $0 }.max()
        }
    }
}
