//
//  BluetoothStore.swift
//  eul
//
//  Created by Gao Sun on 2021/1/18.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

class BluetoothStore: ObservableObject {
    @Published var devices: [BluetoothDevice] = []

    func fetch() {
        guard let data = shellData(["system_profiler SPBluetoothDataType -json"]) else {
            devices = []
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = btArray.first,
              let connected = first["device_connected"] as? [[String: Any]]
        else {
            devices = []
            return
        }

        devices = connected.compactMap { dict -> BluetoothDevice? in
            guard let entry = dict.first,
                  let props = entry.value as? [String: String]
            else { return nil }

            let name = entry.key
            guard let address = props["device_address"] else { return nil }

            return BluetoothDevice(
                name: name,
                address: address,
                batteryLevel: props["device_batteryLevelMain"],
                batteryLevelLeft: props["device_batteryLevelLeft"],
                batteryLevelRight: props["device_batteryLevelRight"],
                batteryLevelCase: props["device_batteryLevelCase"]
            )
        }
    }
}
