//
//  ByteUnit.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

/// edited from https://gist.github.com/fethica/52ef6d842604e416ccd57780c6dd28e6
public struct ByteUnit {
    public let bytes: UInt64
    public let kilo: UInt64

    public var kilobytes: Double {
        Double(bytes) / Double(kilo)
    }

    public var megabytes: Double {
        kilobytes / Double(kilo)
    }

    public var gigabytes: Double {
        megabytes / Double(kilo)
    }

    public init(_ bytes: UInt64, kilo: UInt64 = 1024) {
        self.bytes = bytes
        self.kilo = kilo
    }

    public init(_ bytes: Double, kilo: UInt64 = 1024) {
        self.bytes = UInt64(bytes.zeroOrAbove)
        self.kilo = kilo
    }

    public init(megaBytes: Double) {
        self.init(megaBytes.zeroOrAbove * Double(1024 * 1024))
    }

    public var readable: String {
        switch bytes {
        case 0..<(kilo * kilo):
            return "\(String(format: "%.\(0)f", kilobytes)) KB"
        case kilo..<(kilo * kilo * kilo):
            return "\(String(format: "%.\(megabytes >= 100 ? 0 : 1)f", megabytes)) MB"
        case (kilo * kilo * kilo)...UInt64.max:
            return "\(String(format: "%.\(gigabytes >= 100 ? 0 : 1)f", gigabytes)) GB"
        default:
            return "\(bytes) Bytes"
        }
    }
}

// MARK: rates (design §4.7, ask 18)

/// "I think in megabits — show me Mb/s, not MB/s." One stored choice applied
/// everywhere a rate renders: bar slot, panel, process rows, Trends widget.
public extension ByteUnit {
    /// value and unit as separate parts so point-of-use UIs can make the
    /// unit itself the clickable affordance. Bits use decimal multiples
    /// (Kb/Mb/Gb), the telecom convention; bytes keep the binary KB/MB/GB.
    func readableParts(inBits: Bool) -> (value: String, unit: String) {
        if inBits {
            let bits = Double(bytes) * 8
            switch bits {
            case ..<1_000_000:
                return (String(format: "%.0f", bits / 1000), "Kb")
            case ..<1_000_000_000:
                let mb = bits / 1_000_000
                return (String(format: mb >= 100 ? "%.0f" : "%.1f", mb), "Mb")
            default:
                let gb = bits / 1_000_000_000
                return (String(format: gb >= 100 ? "%.0f" : "%.1f", gb), "Gb")
            }
        }
        switch bytes {
        case 0..<(kilo * kilo):
            return (String(format: "%.0f", kilobytes), "KB")
        case kilo..<(kilo * kilo * kilo):
            return (String(format: megabytes >= 100 ? "%.0f" : "%.1f", megabytes), "MB")
        default:
            return (String(format: gigabytes >= 100 ? "%.0f" : "%.1f", gigabytes), "GB")
        }
    }

    func readableRate(inBits: Bool) -> String {
        let parts = readableParts(inBits: inBits)
        return "\(parts.value) \(parts.unit)/s"
    }
}
