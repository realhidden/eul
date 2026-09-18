//
//  Preference.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

enum Preference {
    /// How much each strip slot spells out (design §4.7). One decision, not a
    /// layout editor: `full` carries the caps label, `valueOnly` drops it for
    /// the dense-bar minority, `smart` trades the label for the component's
    /// template glyph and tucks a history trace under the value.
    enum slotStyle: String, StringEnum {
        case full
        case valueOnly
        case smart

        var description: String {
            "slot_style.\(rawValue)".localized()
        }
    }

    enum appearance: String, StringEnum {
        case auto
        case dark
        case light

        var description: String {
            "appearance.\(rawValue)".localized()
        }

        var colorScheme: SwiftUI.ColorScheme? {
            switch self {
            case .auto:
                return nil
            case .light:
                return .light
            case .dark:
                return .dark
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .auto:
                return nil
            case .light:
                return NSAppearance(named: .aqua)
            case .dark:
                return NSAppearance(named: .darkAqua)
            }
        }
    }
}
