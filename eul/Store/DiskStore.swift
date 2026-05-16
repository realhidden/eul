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
    @ObservedObject var menuComponentsStore = SharedStore.menuComponents
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

    private var rootAttributes: (size: UInt64, free: UInt64)? {
        guard
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
            let size = attrs[.systemSize] as? UInt64,
            let free = attrs[.systemFreeSize] as? UInt64
        else {
            return nil
        }
        return (size, free)
    }

    var ceilingBytes: UInt64? {
        if let selected = selectedDisk {
            return selected.size
        }
        return rootAttributes?.size
    }

    var freeBytes: UInt64? {
        if let selected = selectedDisk {
            return selected.freeSize
        }
        return rootAttributes?.free
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
            || menuComponentsStore.activeComponents.contains(.Disk)
        else {
            return
        }

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
        activeCancellable = Publishers
            .CombineLatest(componentsStore.$activeComponents, menuComponentsStore.$activeComponents)
            .sink { _ in
                DispatchQueue.main.async {
                    self.refresh()
                }
            }
    }
}
