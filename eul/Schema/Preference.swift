//
//  Preference.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

enum Preference {
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
