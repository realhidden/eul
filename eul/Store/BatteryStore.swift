//
//  BatteryStore.swift
//  eul
//
//  Created by Gao Sun on 2020/8/7.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SystemKit
import WidgetKit

class BatteryStore: ObservableObject, Refreshable {
    private var battery = Battery()

    var io = Info.Battery()

    @Published var isValid = true

    @Published var acPowered = false
    @Published var charged = false
    @Published var charging = false
    @Published var capacity = 0
    @Published var maxCapacity = 0
    @Published var designCapacity = 0
    @Published var cycleCount = 0
    @Published var timeRemaining = "∞"

    var charge: Double {
        io.currentCharge
    }

    var health: Double {
        Double(maxCapacity) / Double(designCapacity)
    }

    /// On Apple Silicon the generic capacity keys report percentages while
    /// DesignCapacity stays in mAh, making health and the mAh display nonsense
    /// (#249); the raw mAh values live in the battery service itself. One
    /// registry read per refresh covers both.
    private static func readRawCapacities() -> (current: Int?, max: Int?) {
        guard let properties = IOHelper.getPropertyList(for: "AppleSmartBattery")?.first else {
            return (nil, nil)
        }
        return (
            properties["AppleRawCurrentCapacity"] as? Int,
            properties["AppleRawMaxCapacity"] as? Int ?? properties["NominalChargeCapacity"] as? Int
        )
    }

    @objc func refresh() {
        io = Info.Battery()

        guard battery.open() == kIOReturnSuccess else {
            // equality-guarded so battery-less Macs don't publish every tick
            if isValid {
                isValid = false
            }
            return
        }

        if !isValid {
            isValid = true
        }

        acPowered = battery.isACPowered()
        charged = battery.isCharged()
        charging = battery.isCharging()
        let raw = Self.readRawCapacities()
        capacity = raw.current ?? battery.currentCapacity()
        maxCapacity = raw.max ?? battery.maxCapactiy()
        designCapacity = battery.designCapacity()
        cycleCount = battery.cycleCount()
        timeRemaining = io.powerSource == .battery ? battery.timeRemainingFormatted() : "∞"
        _ = battery.close()
        writeToContainer()
    }

    func writeToContainer() {
        guard WidgetReloader.shouldWrite(kind: BatteryEntry.kind) else {
            return
        }
        Container.set(BatteryEntry(
            isCharging: charging, acPowered: acPowered, charge: charge, capacity: capacity, maxCapacity: maxCapacity, designCapacity: designCapacity, cycleCount: cycleCount, condition: io.condition
        ))
        WidgetReloader.requestReload(ofKind: BatteryEntry.kind)
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        refresh()
    }
}
