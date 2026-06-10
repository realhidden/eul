//
//  DiskStore.swift
//  eul
//
//  Created by Gao Sun on 2020/11/1.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import SharedLibrary
import SwiftUI

class DiskStore: ObservableObject, Refreshable {
    private var activeCancellable: AnyCancellable?

    @ObservedObject var componentsStore = SharedStore.components
    var config: EulComponentConfig {
        SharedStore.componentConfig[EulComponent.Disk]
    }

    @Published var list: DiskList?

    var selectedDisk: DiskList.Disk? {
        guard config.diskSelection != "" else {
            return nil
        }
        return list?.disks.filter { $0.name == config.diskSelection }.first
    }

    /// With no explicit selection, report the boot volume instead of summing
    /// every mounted volume — APFS volumes share one container, so the sum
    /// counted the same space several times (#250, #182). Cached per refresh:
    /// the capacity query is too expensive for per-render property access.
    private var rootVolume: (size: UInt64, free: UInt64)?

    private static func readRootVolume() -> (size: UInt64, free: UInt64)? {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let size = values.volumeTotalCapacity, size >= 0,
            let free = values.volumeAvailableCapacityForImportantUsage, free >= 0
        else {
            return nil
        }
        return (UInt64(size), UInt64(free))
    }

    var ceilingBytes: UInt64? {
        selectedDisk.map { $0.size } ?? rootVolume?.size
    }

    var freeBytes: UInt64? {
        selectedDisk.map { $0.freeSize } ?? rootVolume?.free
    }

    var usageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling - free, kilo: 1000).readable
    }

    var usagePercentageString: String {
        guard let ceiling = ceilingBytes, let free = freeBytes else {
            return "N/A"
        }
        return (Double(ceiling - free) / Double(ceiling)).percentageString
    }

    var freeString: String {
        guard let free = freeBytes else {
            return "N/A"
        }
        return ByteUnit(free, kilo: 1000).readable
    }

    var totalString: String {
        guard let ceiling = ceilingBytes else {
            return "N/A"
        }
        return ByteUnit(ceiling, kilo: 1000).readable
    }

    @objc func refresh() {
        guard
            componentsStore.activeComponents.contains(.Disk)
            // the panel reads this store regardless of pinned components
            || SharedStore.ui.menuOpened
        else {
            return
        }

        rootVolume = Self.readRootVolume()
        loadDisks()
    }

    /// ungated volume enumeration — the settings Data Sources picker needs
    /// the list even when no Disk component is pinned and the panel is closed
    func loadDisks() {
        guard let volumes = (try? FileManager.default.contentsOfDirectory(atPath: DiskList.volumesPath)) else {
            list = nil
            return
        }

        list = DiskList(disks: volumes.compactMap {
            if $0.starts(with: ".") || $0.contains("com.apple") { return nil }

            let path = DiskList.pathForName($0)
            let url = URL(fileURLWithPath: path)

            guard
                let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
                let size = attributes[FileAttributeKey.systemSize] as? UInt64,
                let freeSize = attributes[FileAttributeKey.systemFreeSize] as? UInt64
            else {
                return nil
            }

            let isEjectable = !((try? url.resourceValues(forKeys: [.volumeIsInternalKey]))?.volumeIsInternal ?? false)

            return DiskList.Disk(
                name: $0,
                size: size,
                freeSize: freeSize,
                isEjectable: isEjectable
            )
        })
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
        // refresh immediately to prevent "N/A"
        activeCancellable = componentsStore.$activeComponents
            .sink { _ in
                DispatchQueue.main.async {
                    self.refresh()
                }
            }
    }
}
