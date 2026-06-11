//
//  PreferenceGeneralView.swift
//  eul
//
//  Created by Gao Sun on 2020/9/12.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import LaunchAtLogin
import Localize_Swift
import SharedLibrary
import SwiftUI

extension Preference {
    /// General pane (design §4.4): start at login, one global refresh
    /// cadence with its energy cost stated inline, Units & formats (the
    /// Settings mirror of the in-place unit clicks, §4.7), hidden-tile
    /// restore, language, appearance, and the update row.
    struct GeneralView: View {
        @ObservedObject var launchAtLogin = LaunchAtLogin.observable
        @EnvironmentObject var preference: PreferenceStore

        // MARK: app card

        private var updateStatusText: String {
            if preference.isUpdateAvailable == nil {
                return "ui.checking_update".localized()
            }
            if preference.isUpdateAvailable == true {
                return "ui.new_version".localized()
            }
            return "ui.up_to_date".localized()
        }

        private var appCard: some View {
            Settings.Card(title: "ui.app".localized()) {
                Settings.Row(
                    title: "eul \(preference.version ?? "")",
                    caption: updateStatusText
                ) {
                    HStack(spacing: 10) {
                        if preference.isUpdateAvailable == true, let url = preference.latestReleaseURL {
                            Settings.QuietButton(title: "ui.download".localized()) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        if let url = preference.repoURL {
                            Settings.QuietButton(title: "GitHub") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                Settings.RowDivider()
                Settings.Row(
                    title: "ui.upgrade_method".localized(),
                    caption: "ui.upgrade_method.\(preference.upgradeMethod.rawValue).description".localized()
                ) {
                    Settings.Segmented(
                        options: PreferenceStore.UpgradeMethod.allCases,
                        label: { "ui.upgrade_method.\($0.rawValue)".localized() },
                        selection: $preference.upgradeMethod
                    )
                }
                Settings.RowDivider()
                Settings.ToggleRow(title: "ui.launch_at_login".localized(), isOn: $launchAtLogin.isEnabled)
                Settings.RowDivider()
                // gates only the hidden-by-system notification; the width
                // governor itself always runs (recovery is not optional)
                Settings.ToggleRow(title: "ui.notify_when_hidden".localized(), isOn: $preference.checkStatusItemVisibility)
            }
        }

        // MARK: display card

        /// one global cadence (design §4.4) driving both refresh loops —
        /// per-monitor refresh rates were assembly, and assembly is deleted
        private var cadenceBinding: Binding<Double> {
            Binding(
                get: { Double(preference.smcRefreshRate) },
                set: {
                    let value = Int($0.rounded())
                    preference.smcRefreshRate = value
                    preference.networkRefreshRate = value
                }
            )
        }

        private var displayCard: some View {
            Settings.Card(title: "ui.display".localized()) {
                Settings.Row(title: "language".localized()) {
                    Picker("", selection: $preference.language) {
                        ForEach(PreferenceStore.availableLanguages, id: \.self) {
                            Text("language.\($0)".localized())
                                .tag($0)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                }
                if #available(OSX 11, *) {
                    Settings.RowDivider()
                    Settings.Row(title: "appearance.mode".localized()) {
                        Settings.Segmented(
                            options: appearance.allCases,
                            label: { $0.description },
                            selection: $preference.appearanceMode
                        )
                    }
                }
                Settings.RowDivider()
                Settings.Row(
                    title: String(format: "settings.refresh".localized(), "\(preference.smcRefreshRate)"),
                    caption: "ui.refresh_energy_note".localized()
                ) {
                    HStack(spacing: 6) {
                        Text("1s")
                            .font(DesignTokens.Typo.sub)
                            .foregroundColor(Settings.secondary)
                        Slider(value: cadenceBinding, in: 1...10, step: 1)
                            .controlSize(.small)
                            .frame(width: 140)
                        Text("10s")
                            .font(DesignTokens.Typo.sub)
                            .foregroundColor(Settings.secondary)
                    }
                }
            }
        }

        // MARK: units card (§4.7 mirror of the in-place unit clicks)

        private var unitsCard: some View {
            Settings.Card(title: "settings.units".localized()) {
                Settings.Row(title: "settings.units.rates".localized()) {
                    Settings.Segmented(
                        options: [false, true],
                        label: { $0 ? "Mb/s" : "MB/s" },
                        selection: $preference.networkRateInBits
                    )
                }
                Settings.RowDivider()
                Settings.Row(title: "temp.temperature".localized()) {
                    Settings.Segmented(
                        options: [TemperatureUnit.celius, .fahrenheit],
                        label: { $0 == .celius ? "°C" : "°F" },
                        selection: $preference.temperatureUnit
                    )
                }
            }
        }

        // MARK: hidden tiles (restore lives here; hiding is point-of-use)

        private var hiddenTileKinds: [PanelTileKind] {
            PanelTileKind.allCases.filter { preference.isTileHidden($0) }
        }

        private var hiddenTilesCard: some View {
            Settings.Card(title: "settings.hidden_tiles".localized()) {
                ForEach(hiddenTileKinds) { kind in
                    Settings.Row(title: kind.localizedDescription) {
                        Settings.QuietButton(title: "settings.restore".localized()) {
                            preference.restoreTile(kind)
                        }
                    }
                    if kind != hiddenTileKinds.last {
                        Settings.RowDivider()
                    }
                }
            }
        }

        private func resetToDefaults() {
            preference.temperatureUnit = .celius
            preference.networkRateInBits = false
            preference.hiddenTiles = []
            preference.smcRefreshRate = 3
            preference.networkRefreshRate = 3
            preference.appearanceMode = .auto
            preference.upgradeMethod = .showInStatusBar
            preference.checkStatusItemVisibility = true
            Localize.resetCurrentLanguageToDefault()
            preference.language = Localize.currentLanguage()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DesignTokens.Panel.spacing) {
                appCard
                displayCard
                unitsCard
                if !hiddenTileKinds.isEmpty {
                    hiddenTilesCard
                }
                Settings.ResetRow(action: resetToDefaults)
            }
        }
    }
}
