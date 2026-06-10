//
//  CpuStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SystemKit
import WidgetKit

class CpuStore: ObservableObject, Refreshable {
    @Published var temp: Double?
    @Published var usageCPU: (system: Double, user: Double, idle: Double, nice: Double)?
    @Published var loadAverage: [Double]?
    @Published var physicalCores = 0
    @Published var logicalCores = 0
    @Published var upTime: (days: Int, hrs: Int, mins: Int, secs: Int)?
    @Published var thermalLevel: System.ThermalLevel = .Unknown
    @Published var usageHistory: [Double] = []
    @Published var coreUsages: [Double] = []
    @Published var coreLabels: [String] = []

    private var previousCoreTicks: [[Int]] = []
    private var efficiencyCoreCount = 0

    var loadAverage1MinString: String {
        formatDouble(loadAverage?[safe: 0])
    }

    var loadAverage5MinString: String {
        formatDouble(loadAverage?[safe: 1])
    }

    var loadAverage15MinString: String {
        formatDouble(loadAverage?[safe: 2])
    }

    var usageString: String {
        guard let usage = usageCPU else {
            return "N/A"
        }
        return String(format: "%.0f%%", usage.system + usage.user)
    }

    var upTimeString: String? {
        guard let upTime = upTime else {
            return nil
        }
        if upTime.days > 0 {
            return "\(upTime.days)d \(upTime.hrs)h \(upTime.mins)m"
        }
        return "\(upTime.hrs)h \(upTime.mins)m"
    }

    var usage: Double? {
        guard let usageCPU = usageCPU else {
            return nil
        }
        return usageCPU.system + usageCPU.user
    }

    private func formatDouble(_ value: Double?) -> String {
        guard let value = value else {
            return "N/A"
        }
        return String(format: "%.2f", value)
    }

    private func getInfo() {
        physicalCores = System.physicalCores()
        logicalCores = System.logicalCores()
        upTime = System.uptime()
        thermalLevel = System.thermalLevel()
        #if arch(arm64)
            efficiencyCoreCount = Self.sysctlInt("hw.perflevel1.physicalcpu")
        #endif
    }

    private static func sysctlInt(_ name: String) -> Int {
        var value = 0
        var size = MemoryLayout<Int>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private func getUsage() {
        let usage = Info.system.usageCPU()
        usageCPU = usage
        loadAverage = System.loadAverage()
        usageHistory = (usageHistory + [usage.system + usage.user]).suffix(LineChart.defaultMaxPointCount)
        coreUsages = computePerCoreUsage()
    }

    private func computePerCoreUsage() -> [Double] {
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        var coreCount: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &coreCount,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return []
        }

        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var currentTicks: [[Int]] = []
        var usages: [Double] = []
        var labels: [String] = []

        for core in 0..<Int(coreCount) {
            let offset = core * Int(CPU_STATE_MAX)
            let user = Int(info[offset + Int(CPU_STATE_USER)])
            let system = Int(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle = Int(info[offset + Int(CPU_STATE_IDLE)])
            let nice = Int(info[offset + Int(CPU_STATE_NICE)])

            currentTicks.append([user, system, idle, nice])

            if efficiencyCoreCount > 0 {
                // Apple Silicon enumerates the efficiency cluster first
                labels.append(core < efficiencyCoreCount ? "E\(core)" : "P\(core - efficiencyCoreCount)")
            } else {
                labels.append("C\(core)")
            }

            guard core < previousCoreTicks.count else {
                usages.append(0)
                continue
            }

            let previous = previousCoreTicks[core]
            let busy = (user - previous[0]) + (system - previous[1]) + (nice - previous[3])
            let total = busy + (idle - previous[2])
            usages.append(total > 0 ? Double(busy) / Double(total) * 100 : 0)
        }

        previousCoreTicks = currentTicks
        coreLabels = labels

        return usages
    }

    private func getTemp() {
        temp = (SmcControl.shared.cpuDieTemperature ?? 0) > 0
            ? SmcControl.shared.cpuDieTemperature
            : SmcControl.shared.cpuProximityTemperature
    }

    @objc func refresh() {
        getInfo()
        getUsage()
        getTemp()
        writeToContainer()
    }

    func writeToContainer() {
        Container.set(CpuEntry(
            temp: temp,
            usageSystem: usageCPU?.system,
            usageUser: usageCPU?.user,
            usageNice: usageCPU?.nice
        ))
        WidgetReloader.requestReload(ofKind: CpuEntry.kind)
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
    }
}
