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
    var cores: Int?

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

        return plistArray.first?.items.compactMap { item -> GPU? in
            guard item.isGPU, let deviceId = item.resolvedDeviceId else {
                return nil
            }
            return GPU(
                deviceId: deviceId,
                model: item.model,
                vendor: item.vendor,
                cores: Int(item.cores ?? "")
            )
        }
    }

    /// https://stackoverflow.com/questions/10110658/programmatically-get-gpu-percent-usage-in-os-x/22440235#22440235
    /// https://github.com/exelban/stats/blob/master/Modules/GPU/reader.swift
    static func getInfo() -> [Statistic]? {
        guard let propertyList = IOHelper.getPropertyList(for: kIOAcceleratorClassName) else {
            return nil
        }

        // Apple Silicon accelerators (AGXAccelerator) expose PerformanceStatistics
        // but no IOPCIMatch, hence the placeholder match and defaulted usage
        let statistics: [Statistic] = propertyList.compactMap {
            guard let performance = $0["PerformanceStatistics"] as? [String: Any] else {
                return nil
            }

            Print("📊 statistics", performance)

            return Statistic(
                pciMatch: $0["IOPCIMatch"] as? String ?? $0["IOPCIPrimaryMatch"] as? String ?? "apple-silicon-gpu",
                usagePercentage: performance["Device Utilization %"] as? Int ?? performance["GPU Activity(%)"] as? Int ?? 0,
                temperature: performance["Temperature(C)"] as? Double ?? SmcControl.shared.gpuProximityTemperature,
                coreClock: performance["Core Clock(MHz)"] as? Int,
                memoryClock: performance["Memory Clock(MHz)"] as? Int
            )
        }

        return statistics.isEmpty ? nil : statistics
    }
}
