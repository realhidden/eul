//
//  PreferenceEntry.swift
//  eul
//
//  Created by Gao Sun on 2020/11/7.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

public struct PreferenceEntry: SharedEntry {
    public init(temperatureUnit: TemperatureUnit = TemperatureUnit.celius, appearanceMode: String = "auto") {
        self.temperatureUnit = temperatureUnit
        self.appearanceMode = appearanceMode
    }

    public static let containerKey = "PreferenceEntry"

    public var temperatureUnit = TemperatureUnit.celius
    public var appearanceMode = "auto"

    public var colorScheme: SwiftUI.ColorScheme? {
        switch appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
