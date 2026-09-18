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
