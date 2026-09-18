//
//  EulComponent.swift
//  eul
//
//  Created by Gao Sun on 2020/8/22.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SwiftUI
import SwiftyJSON

enum EulComponent: String, CaseIterable, Identifiable, Codable, JSONCodabble, LocalizedStringConvertible {
    var id: String {
        rawValue
    }

    var localizedDescription: String {
        "component.\(rawValue.lowercased())".localized()
    }

    /// The SF Symbol that stands for this component, when one exists.
    ///
    /// Symbols are weight-matched to the system font, tint themselves, and
    /// stay crisp at any size — everything a menu bar glyph needs and a
    /// bitmap cannot give. There is no `gpu` symbol (verified absent as of
    /// macOS 26), so the GPU keeps its bundled template PDF; `ComponentGlyph`
    /// falls back to the asset for any name the running system lacks.
    var symbolName: String? {
        switch self {
        case .CPU:
            return "cpu"
        case .Memory:
            return "memorychip"
        case .GPU:
            return nil
        case .Disk:
            return "internaldrive"
        case .Network:
            return "arrow.up.arrow.down"
        case .Fan:
            return "fanblades"
        case .Battery:
            return "battery.100"
        }
    }

    var isDiskSelectionAvailable: Bool {
        self == .Disk
    }

    var isNetworkInterfaceSelectionAvailable: Bool {
        self == .Network
    }

    case CPU
    case Fan
    case Memory
    case Battery
    case Network
    case Disk
    case GPU

    static var allCases: [EulComponent] {
        [.CPU, .GPU, .Memory]
            .appending(.Fan, condition: SmcControl.shared.isFanValid)
            .appending(.Network)
            .appending(.Battery, condition: SharedStore.battery.isValid)
            .appending(.Disk)
    }

    static var defaultComponents: [EulComponent] {
        // design §2.8 out-of-box: anchor + CPU + NET; everything else is one
        // click away in the panel, and the glyph carries health
        [.CPU, .Network]
    }
}
