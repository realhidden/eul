//
//  Info.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Darwin
import Foundation
import IOKit.ps
import SharedLibrary
import SystemConfiguration
import SystemKit

extension BatteryEntry.BatteryCondition {
    var description: String {
        "battery.condition.\(rawValue)".localized()
    }
}

extension BatteryEntry.PowerSourceState {
    var description: String {
        "battery.power_source.\(rawValue)".localized()
    }
}

enum Info {
    static var isBigSur: Bool {
        if #available(OSX 11, *) {
            return true
        }
        return false
    }

    struct Battery {
        var currentCapacity = 0
        var maxCapacity = 0
        var currentCharge: Double {
            Double(currentCapacity) / Double(maxCapacity)
        }

        var condition: BatteryEntry.BatteryCondition = .good
        var powerSource: BatteryEntry.PowerSourceState = .unknown
        var timeToFullCharge = 0
        var timeToEmpty = 0
        var isCharged = false
        var isCharging = false

        init() {
            guard
                let blob = IOPSCopyPowerSourcesInfo(),
                let list = IOPSCopyPowerSourcesList(blob.takeRetainedValue()),
                let array = list.takeRetainedValue() as? [Any],
                array.count > 0,
                let dict = array[0] as? NSDictionary
            else {
                return
            }

            currentCapacity = dict[kIOPSCurrentCapacityKey] as? Int ?? 0
            maxCapacity = dict[kIOPSMaxCapacityKey] as? Int ?? 0
            timeToFullCharge = dict[kIOPSTimeToFullChargeKey] as? Int ?? 0
            timeToEmpty = dict[kIOPSTimeToEmptyKey] as? Int ?? 0
            isCharged = dict[kIOPSIsChargedKey] as? Bool ?? false
            isCharging = dict[kIOPSIsChargingKey] as? Bool ?? false

            if let value = dict[kIOPSBatteryHealthConditionKey] as? String {
                switch value {
                case kIOPSPoorValue:
                    condition = .poor
                case kIOPSFairValue:
                    condition = .fair
                default:
                    condition = .good
                }
            }

            if let value = dict[kIOPSPowerSourceStateKey] as? String {
                switch value {
                case kIOPSACPowerValue:
                    powerSource = .acPower
                case kIOPSBatteryPowerValue:
                    powerSource = .battery
                default:
                    powerSource = .unknown
                }
            }

            Print(
                "🔋 battery info",
                currentCapacity,
                maxCapacity,
                timeToFullCharge,
                timeToEmpty,
                isCharged,
                isCharging,
                condition,
                powerSource
            )
        }
    }

    struct NetworkUsage {
        var inBytes: UInt64
        var outBytes: UInt64
    }

    struct NetworkPort: Identifiable {
        var port: String?
        var device: String

        var id: String {
            device
        }

        var description: String {
            guard let port = port else {
                return device
            }
            return "\(port) (\(device))"
        }
    }

    /// One address bound to one interface. An adapter commonly has several
    /// (IPv4 + global IPv6 + link-local IPv6), so this is a flat list keyed by
    /// device rather than a single address per port.
    struct InterfaceAddress: Identifiable {
        var device: String
        var address: String
        var isIPv6: Bool
        var isLoopback: Bool

        var id: String {
            "\(device)|\(address)"
        }
    }

    /// Every address on every up interface, loopback included — getifaddrs
    /// reports the kernel's actual bindings, which is what `ifconfig` prints
    /// and what the configd service list (orderedNetworkServices) does not
    /// carry. Down interfaces are skipped: they have no address to show.
    static func getInterfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return []
        }
        defer {
            freeifaddrs(head)
        }

        var result = [InterfaceAddress]()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, let sockaddr = pointer.pointee.ifa_addr else {
                continue
            }

            let family = sockaddr.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sockaddr,
                socklen_t(sockaddr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            // link-local IPv6 comes back scoped ("fe80::1%en0"); the row
            // already names the device, so the suffix is redundant noise
            let address = String(cString: host).components(separatedBy: "%")[0]
            guard !address.isEmpty else {
                continue
            }

            result.append(InterfaceAddress(
                device: String(cString: pointer.pointee.ifa_name),
                address: address,
                isIPv6: family == UInt8(AF_INET6),
                isLoopback: flags & IFF_LOOPBACK == IFF_LOOPBACK
            ))
        }
        return result
    }

    static func findPort(_ string: String) -> NetworkPort? {
        guard string.hasPrefix("("), string.hasSuffix(")") else {
            return nil
        }

        let trimmed = String(string.dropFirst().dropLast())

        guard let matched = trimmed.firstMatch("Device: ([^,]+)")?.range(at: 1), let deviceRange = Range(matched, in: trimmed) else {
            return nil
        }

        var port: String?
        let device = String(trimmed[deviceRange])
        if let matched = trimmed.firstMatch("Port: ([^,]+)")?.range(at: 1), let portRange = Range(matched, in: trimmed) {
            port = String(trimmed[portRange])
        }

        return NetworkPort(port: port, device: device)
    }

    /// SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq); the _IOWR macro
    /// doesn't import into Swift — value derived from the macOS SDK headers
    /// where sizeof(struct ifmediareq) == 44 (0x2C)
    private static let SIOCGIFMEDIA: UInt = 0xC02C_6938
    // status bits per net/if_media.h
    private static let IFM_AVALID: Int32 = 0x0000_0001
    private static let IFM_ACTIVE: Int32 = 0x0000_0002

    static func getActiveInterfaces() -> [String] {
        // virtual link-layer helpers report "active" too and shadow the real
        // port (#226); exclude them rather than allowlisting en*/ap* so
        // Thunderbolt/USB bridges and future physical types keep working
        let virtualInterfacePrefixes = ["lo", "awdl", "llw", "utun", "gif", "stf"]

        var addressList: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addressList) == 0 else {
            return []
        }
        defer { freeifaddrs(addressList) }

        var names = [String]()
        var pointer = addressList
        while let address = pointer?.pointee {
            pointer = address.ifa_next

            guard address.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let cName = address.ifa_name else {
                continue
            }

            let name = String(cString: cName)
            if !names.contains(name), !virtualInterfacePrefixes.contains(where: { name.hasPrefix($0) }) {
                names.append(name)
            }
        }

        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0)

        guard socketDescriptor >= 0 else {
            return []
        }
        defer { close(socketDescriptor) }

        return names.filter { name in
            // the same check ifconfig uses to print "status: active"; an
            // ioctl failure means no media support, which ifconfig reports
            // with no status line at all
            var request = ifmediareq()
            withUnsafeMutablePointer(to: &request.ifm_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) { destination in
                    _ = name.withCString { strlcpy(destination, $0, Int(IFNAMSIZ)) }
                }
            }

            guard ioctl(socketDescriptor, SIOCGIFMEDIA, &request) == 0 else {
                return false
            }

            return request.ifm_status & IFM_AVALID != 0 && request.ifm_status & IFM_ACTIVE != 0
        }
    }

    /// 64-bit `if_data64` interface counters — the same numbers `netstat -bI`
    /// prints, without spawning a process. the NET_RT_IFLIST2 route dump is
    /// deliberately avoided: the kernel quantizes its ifi_ibytes/ifi_obytes
    /// to 1KiB and wraps them at 4GiB for non-Apple-signed binaries, while
    /// the per-interface IFMIB_IFDATA sysctl stays full precision
    private static func interfaceBytes(forDevice device: String) -> (inBytes: UInt64, outBytes: UInt64)? {
        let index = if_nametoindex(device)

        guard index > 0 else {
            return nil
        }

        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var data = ifmibdata()
        var size = MemoryLayout<ifmibdata>.size

        guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0 else {
            return nil
        }

        return (data.ifmd_data.ifi_ibytes, data.ifmd_data.ifi_obytes)
    }

    /// the same user-defined order `networksetup -listnetworkserviceorder`
    /// prints, read straight from the configd store
    private static func orderedNetworkServices() -> [NetworkPort] {
        guard
            let preferences = SCPreferencesCreate(nil, "eul" as CFString, nil),
            let set = SCNetworkSetCopyCurrent(preferences),
            let serviceIDs = SCNetworkSetGetServiceOrder(set) as? [CFString]
        else {
            return []
        }

        return serviceIDs.compactMap { id in
            guard let service = SCNetworkServiceCopy(preferences, id) else {
                return nil
            }

            let interfaceInfo = SCPreferencesPathGetValue(preferences, "/NetworkServices/\(id)/Interface" as CFString) as? [String: Any]

            // networksetup hides services whose interface is flagged
            // HiddenConfiguration (e.g. auto-created "Ethernet Adapter" ports)
            guard interfaceInfo?["HiddenConfiguration"] as? Bool != true else {
                return nil
            }

            // DeviceName covers modem-style ports without a BSD name (the
            // Device field networksetup prints); device-less services are
            // dropped just like the old parser did
            guard
                let device = SCNetworkServiceGetInterface(service).flatMap({ SCNetworkInterfaceGetBSDName($0) }) as String?
                ?? interfaceInfo?["DeviceName"] as? String
            else {
                return nil
            }

            return NetworkPort(port: SCNetworkServiceGetName(service) as String?, device: device)
        }
    }

    static func getNetworkUsage(forDevice: String?, _ onData: @escaping (NetworkUsage, [NetworkPort], NetworkPort?, [InterfaceAddress]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let services = orderedNetworkServices()
            let activeInterfaces = getActiveInterfaces()
            let currentActivePort = services.first(where: { activeInterfaces.contains($0.device) })

            Print("network services order", services)
            Print("network active interfaces", activeInterfaces)
            Print("network current active interfaces", currentActivePort ?? "N/A")

            let device = forDevice ?? currentActivePort?.device ?? "en0"
            let bytes = interfaceBytes(forDevice: device)
            let addresses = getInterfaceAddresses()

            DispatchQueue.main.async {
                onData(NetworkUsage(inBytes: bytes?.inBytes ?? 0, outBytes: bytes?.outBytes ?? 0), services, currentActivePort, addresses)
            }
        }
    }

    static var system = System()

    static func getProcessCommand(pid: Int) -> String? {
        shell("ps -p \(pid) -o comm=")?.trimmingCharacters(in: .newlines)
    }
}
