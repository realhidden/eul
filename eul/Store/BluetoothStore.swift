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
    private var isFetching = false
    private var lastFetchedAt: Date?
    /// each fetch spawns a ~1-2 s system_profiler subprocess — rapid panel
    /// reopens shouldn't pay that repeatedly
    private static let fetchInterval: TimeInterval = 60

    /// system_profiler blocks for up to ~2 s — never run it on the main
    /// thread; the panel triggers this on open
    func fetchAsync() {
        guard !isFetching else {
            return
        }
        if let lastFetchedAt = lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.fetchInterval {
            return
        }
        isFetching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.read()
            DispatchQueue.main.async {
                self?.devices = result
                self?.isFetching = false
                self?.lastFetchedAt = Date()
            }
        }
    }

    func fetch() {
        devices = Self.read()
    }

    private static func read() -> [BluetoothDevice] {
        guard let data = shellData(["system_profiler SPBluetoothDataType -json"]) else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = btArray.first,
              let connected = first["device_connected"] as? [[String: Any]]
        else {
            return []
        }

        return connected.compactMap { dict -> BluetoothDevice? in
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
