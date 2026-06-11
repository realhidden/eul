//
//  NetworkStore.swift
//  eul
//
//  Created by Gao Sun on 2020/8/9.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import WidgetKit

class NetworkStore: ObservableObject, Refreshable {
    private var networkUsageHasBeenSet = true
    private var requestGeneration = 0
    private var consecutiveWatchdogFires = 0
    private var lastTimestamp: TimeInterval

    @Published var networkUsage = Info.NetworkUsage(inBytes: 0, outBytes: 0)
    @Published var ports = [Info.NetworkPort]()
    @Published var currentActivePort: Info.NetworkPort?

    @Published var inSpeedInByte: Double = 0
    @Published var outSpeedInByte: Double = 0

    var config: EulComponentConfig {
        SharedStore.componentConfig[EulComponent.Network]
    }

    var inSpeed: String {
        ByteUnit(inSpeedInByte).readableRate(inBits: SharedStore.preference.networkRateInBits)
    }

    var outSpeed: String {
        ByteUnit(outSpeedInByte).readableRate(inBits: SharedStore.preference.networkRateInBits)
    }

    var autoPortDesscription: String {
        guard let currentActivePort = currentActivePort else {
            return "network.port.auto".localized()
        }

        return "\("network.port.auto".localized()) (\(currentActivePort.device))"
    }

    @objc func refresh() {
        guard networkUsageHasBeenSet else {
            return
        }

        networkUsageHasBeenSet = false
        requestGeneration += 1
        let generation = requestGeneration

        // Re-open the single-flight guard if this request's callback never
        // arrives, otherwise the network display freezes permanently (#263).
        // The generation check keeps a stale watchdog from re-opening the
        // guard while a younger request is in flight; the fire counter stops
        // re-arming during a persistent hang so hung shell pipelines don't
        // accumulate without bound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            guard generation == requestGeneration, !networkUsageHasBeenSet else {
                return
            }
            consecutiveWatchdogFires += 1
            if consecutiveWatchdogFires < 5 {
                networkUsageHasBeenSet = true
            } else if consecutiveWatchdogFires == 5 {
                print("network refresh pipeline hung repeatedly, giving up until relaunch")
            }
        }

        Info.getNetworkUsage(forDevice: config.networkPortSelection.nilIfEmpty) { [self] current, ports, currentActivePort in
            // delivered on the main queue (see Info.getNetworkUsage); ignore
            // results that arrive after a newer request superseded this one
            guard generation == requestGeneration else {
                return
            }

            let time = Date().timeIntervalSince1970
            let elapsed = time - lastTimestamp

            if networkUsage.inBytes > 0, elapsed > 0.1 {
                // interface counters reset on reconnect/wrap: treat as zero (#226)
                let delta = current.inBytes >= networkUsage.inBytes ? current.inBytes - networkUsage.inBytes : 0
                inSpeedInByte = Double(delta) / elapsed
            } else {
                inSpeedInByte = 0
            }

            if networkUsage.outBytes > 0, elapsed > 0.1 {
                let delta = current.outBytes >= networkUsage.outBytes ? current.outBytes - networkUsage.outBytes : 0
                outSpeedInByte = Double(delta) / elapsed
            } else {
                outSpeedInByte = 0
            }

            lastTimestamp = time
            networkUsage = current
            self.ports = ports
            self.currentActivePort = currentActivePort
            consecutiveWatchdogFires = 0
            writeToContainer()
            networkUsageHasBeenSet = true
        }
    }

    func writeToContainer() {
        Container.set(NetworkEntry(inSpeedInByte: inSpeedInByte, outSpeedInByte: outSpeedInByte))
        WidgetReloader.requestReload(ofKind: NetworkEntry.kind)
    }

    init() {
        lastTimestamp = Date().timeIntervalSince1970
        initObserver(for: .NetworkShouldRefresh)
    }
}
