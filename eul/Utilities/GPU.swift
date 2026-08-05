//
//  GPU.swift
//  eul
//
//  Created by Gao Sun on 2021/1/23.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

struct GPU: Identifiable {
    var deviceId: String
    var model: String?
    var vendor: String?

    var id: String {
        deviceId
    }
}

extension GPU {
    struct Statistic {
        var pciMatch: String
        var usagePercentage: Int
        var temperature: Double?
        var coreClock: Int?
        var memoryClock: Int?
    }
}

extension GPU {
    static func getGPUs() -> [GPU]? {
        guard let data = shellData(["system_profiler SPDisplaysDataType -xml"]) else {
            return nil
        }

        let pListDecoder = PropertyListDecoder()
        guard let plistArray = try? pListDecoder.decode(SystemProfilerPlistArray.self, from: data) else {
            return nil
        }

        return plistArray.first?.items.compactMap {
            guard $0.isGPU else {
                return nil
            }
            // For Apple Silicon GPUs, use model name as identifier if device-id is not available
            let deviceId = $0.deviceId ?? $0.model ?? "unknown"
            return GPU(deviceId: deviceId, model: $0.model, vendor: $0.vendor)
        }
    }

    // https://stackoverflow.com/questions/10110658/programmatically-get-gpu-percent-usage-in-os-x/22440235#22440235
    // https://github.com/exelban/stats/blob/master/Modules/GPU/reader.swift
    static func getInfo() -> [Statistic]? {
        guard let propertyList = IOHelper.getPropertyList(for: kIOAcceleratorClassName) else {
            return nil
        }

        return propertyList.compactMap {
            // For Intel GPUs, use IOPCIMatch for device identification
            // For Apple Silicon, IOPCIMatch may not be available, so use a fallback
            let pciMatch = $0["IOPCIMatch"] as? String ?? $0["IOPCIPrimaryMatch"] as? String

            let statistics = $0["PerformanceStatistics"] as? [String: Any]

            // Try to get usage percentage from various keys
            var usagePercentage: Int?
            if let stats = statistics {
                usagePercentage = stats["Device Utilization %"] as? Int ??
                    stats["GPU Activity(%)"] as? Int ??
                    stats["GPU Core Utilization"] as? Int
            }

            // For Apple Silicon, try alternative methods if PerformanceStatistics is not available
            if usagePercentage == nil {
                // Try IOAcceleratorStatistics2 for Apple Silicon
                if let stats2 = $0["IOAcceleratorStatistics2"] as? [String: Any] {
                    usagePercentage = stats2["Device Utilization %"] as? Int ??
                        stats2["GPU Activity(%)"] as? Int
                }
            }

            // If still no usage data, default to 0 instead of failing
            let finalUsage = usagePercentage ?? 0

            Print("📊 statistics", statistics ?? [:])

            // Try to get temperature from various sources
            var temperature: Double?
            if let stats = statistics {
                temperature = stats["Temperature(C)"] as? Double
            }

            // Fallback to SMC for temperature
            if temperature == nil || temperature == 0 {
                temperature = SmcControl.shared.gpuProximityTemperature
            }

            // For Apple Silicon, use "apple" as pciMatch if not available
            // This allows matching with GPU devices that use model name as deviceId
            let finalPciMatch = pciMatch ?? "apple"

            return Statistic(
                pciMatch: finalPciMatch,
                usagePercentage: finalUsage,
                temperature: temperature,
                coreClock: statistics?["Core Clock(MHz)"] as? Int,
                memoryClock: statistics?["Memory Clock(MHz)"] as? Int
            )
        }
    }
}
