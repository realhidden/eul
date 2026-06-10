//
//  PreferenceDisplayView.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Localize_Swift
import SharedLibrary
import SwiftUI

extension Preference {
    /// Display half of the General pane (design §4.4): language, units,
    /// appearance, and the refresh cadence with its energy cost stated
    /// inline. The 1.x text-display and font-design pickers are deleted —
    /// one type system, tabular by law (§5.1).
    struct DisplayView: View {
        let temperatureUnits: [TemperatureUnit] = [.celius, .fahrenheit]
        let appearanceMode = appearance.allCases
        let allIntervals: [Int] = [1, 3, 5]
        @EnvironmentObject var preference: PreferenceStore

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Picker("language".localized(), selection: $preference.language) {
                    ForEach(PreferenceStore.availableLanguages, id: \.self) {
                        Text("language.\($0)".localized())
                            .tag($0)
                    }
                }
                .frame(width: 200)
                Picker("temp.temperature".localized(), selection: $preference.temperatureUnit) {
                    ForEach(temperatureUnits, id: \.self) {
                        Text($0.description)
                            .tag($0)
                    }
                }
                .frame(width: 200)
                // Disable in Catalina to avoid protential crash
                if #available(OSX 11, *) {
                    Picker("appearance.mode".localized(), selection: $preference.appearanceMode) {
                        ForEach(appearanceMode) {
                            Text($0.description)
                                .tag($0)
                        }
                    }
                    .frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Picker("ui.smc".localized(), selection: $preference.smcRefreshRate) {
                            ForEach(allIntervals, id: \.self) {
                                Text("\($0)s")
                                    .tag($0)
                            }
                        }
                        .frame(width: 150)
                        Picker("ui.network".localized(), selection: $preference.networkRefreshRate) {
                            ForEach(allIntervals, id: \.self) {
                                Text("\($0)s")
                                    .tag($0)
                            }
                        }
                        .frame(width: 150)
                    }
                    Text("ui.refresh_energy_note".localized())
                        .secondaryDisplayText()
                }
            }
            .padding(.vertical, 8)
        }
    }
}
