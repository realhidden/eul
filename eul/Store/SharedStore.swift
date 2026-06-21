//
//  SharedStore.swift
//  eul
//
//  Created by Gao Sun on 2020/11/24.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

enum SharedStore {
    static let visibilityCheckClosure = { StatusBarManager.shared.checkVisibilityIfNeeded() }
    static let battery = BatteryStore()
    static let cpu = CpuStore()
    static let gpu = GpuStore()
    static let topStore = TopStore()
    static let disk = DiskStore()
    static let fan = FanStore()
    static let memory = MemoryStore()
    static let network = NetworkStore()
    static let networkTop = NetworkTopStore()
    static let bluetooth = BluetoothStore()
    static let preference = PreferenceStore()
    static let ui = UIStore()
    static let health = HealthStore()
    static let fanControl = FanControlStore()
    static let cleanMode = CleanModeManager()
    static let components = ComponentsStore<EulComponent>(
        defaultComponents: EulComponent.defaultComponents,
        onDidChange: visibilityCheckClosure
    )
    static let componentConfig = ComponentConfigStore(onDidChange: visibilityCheckClosure)
}

extension View {
    func withGlobalEnvironmentObjects() -> some View {
        environmentObject(SharedStore.ui)
            .environmentObject(SharedStore.battery)
            .environmentObject(SharedStore.cpu)
            .environmentObject(SharedStore.gpu)
            .environmentObject(SharedStore.fan)
            .environmentObject(SharedStore.memory)
            .environmentObject(SharedStore.network)
            .environmentObject(SharedStore.networkTop)
            .environmentObject(SharedStore.disk)
            .environmentObject(SharedStore.bluetooth)
            .environmentObject(SharedStore.preference)
            .environmentObject(SharedStore.components)
            .environmentObject(SharedStore.componentConfig)
            .environmentObject(SharedStore.topStore)
            .environmentObject(SharedStore.health)
            .environmentObject(SharedStore.fanControl)
            .environmentObject(SharedStore.cleanMode)
    }
}
