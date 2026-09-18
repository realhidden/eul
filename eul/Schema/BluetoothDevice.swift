//
//  BluetoothDevice.swift
//  eul
//
//  Created by Gao Sun on 2021/1/22.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

struct BluetoothDevice: Identifiable {
    let name: String
    let address: String
    let batteryLevel: String?
    let batteryLevelLeft: String?
    let batteryLevelRight: String?
    let batteryLevelCase: String?

    var id: String {
        address
    }

    var displayName: String {
        name
    }

    var hasBattery: Bool {
        batteryLevel != nil
            || batteryLevelLeft != nil
            || batteryLevelRight != nil
            || batteryLevelCase != nil
    }

    var batteryPercent: Int? {
        guard let str = batteryLevel else { return nil }
        return Int(str.replacingOccurrences(of: "%", with: ""))
    }

    var batteryPercentLeft: Int? {
        guard let str = batteryLevelLeft else { return nil }
        return Int(str.replacingOccurrences(of: "%", with: ""))
    }

    var batteryPercentRight: Int? {
        guard let str = batteryLevelRight else { return nil }
        return Int(str.replacingOccurrences(of: "%", with: ""))
    }

    var batteryPercentCase: Int? {
        guard let str = batteryLevelCase else { return nil }
        return Int(str.replacingOccurrences(of: "%", with: ""))
    }
}
