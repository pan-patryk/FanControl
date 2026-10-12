import Foundation

// MARK: - Models for JSON Parsing
struct FanJSON: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let currentSpeed: Int
    let minSpeed: Int
    let maxSpeed: Int
    let targetSpeed: Int
    let mode: Int
}

struct SystemStatusJSON: Codable {
    let fans: [FanJSON]
    let cpuTemp: Double?
    let gpuTemp: Double?
    let batteryTemp: Double?
}

// MARK: - Thermal vocabulary
//
// `TemperatureSensor` (Models/TemperatureSensor.swift) is the key of the gates, the
// curves, the charts and `history.jsonl`. The percent↔rpm conversion is in
// `FanPercentage` (Core/FanPercentage.swift), not here, so every writer and every
// reader agrees on what "40 % of this fan's range" means.

