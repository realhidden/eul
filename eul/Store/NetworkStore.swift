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
    @Published var interfaceAddresses = [Info.InterfaceAddress]()

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

    /// Addresses grouped per adapter, in the user's configured service order
    /// first (so Wi-Fi/Ethernet lead), then anything the service list doesn't
    /// name — loopback, bridges, VPN utun links — in kernel order.
    struct Adapter: Identifiable {
        var device: String
        /// the service name when configd knows one ("Wi-Fi"), else nil
        var name: String?
        var addresses: [Info.InterfaceAddress]

        var id: String {
            device
        }

        var title: String {
            guard let name = name else {
                return device
            }
            return "\(name) (\(device))"
        }
    }

    var adapters: [Adapter] {
        var order = [String]()
        var grouped = [String: [Info.InterfaceAddress]]()
        for address in interfaceAddresses {
            if grouped[address.device] == nil {
                order.append(address.device)
            }
            grouped[address.device, default: []].append(address)
        }

        let names = Dictionary(ports.map { ($0.device, $0.port) }, uniquingKeysWith: { first, _ in first })
        let ranked = order.sorted { lhs, rhs in
            let lhsRank = ports.firstIndex { $0.device == lhs } ?? Int.max
            let rhsRank = ports.firstIndex { $0.device == rhs } ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            // stable tiebreak for everything configd doesn't rank
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }

        return ranked.map { device in
            // IPv4 before IPv6 so the address people actually quote leads
            let addresses = (grouped[device] ?? []).sorted { lhs, rhs in
                lhs.isIPv6 == rhs.isIPv6 ? lhs.address < rhs.address : !lhs.isIPv6
            }
            return Adapter(device: device, name: names[device] ?? nil, addresses: addresses)
        }
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
                print("⚠️ Network refresh pipeline hung repeatedly (5+ times), giving up until relaunch")
            }
        }

        // Reset the guard after 10s in case the async command never completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            networkUsageHasBeenSet = true
        }

        Info.getNetworkUsage(forDevice: config.networkPortSelection.nilIfEmpty) { [self] current, ports, currentActivePort, addresses in
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
            if addresses.map({ $0.id }) != interfaceAddresses.map({ $0.id }) {
                // every refresh re-reads them, but addresses change rarely —
                // only publish on a real change so the panel doesn't re-render
                // the whole adapter list every few seconds
                interfaceAddresses = addresses
            }
            consecutiveWatchdogFires = 0
            writeToContainer()
            networkUsageHasBeenSet = true
        }
    }

    func writeToContainer() {
        guard WidgetReloader.shouldWrite(kind: NetworkEntry.kind) else {
            return
        }
        Container.set(NetworkEntry(inSpeedInByte: inSpeedInByte, outSpeedInByte: outSpeedInByte))
        WidgetReloader.requestReload(ofKind: NetworkEntry.kind)
    }

    init() {
        lastTimestamp = Date().timeIntervalSince1970
        initObserver(for: .NetworkShouldRefresh)
    }
}
