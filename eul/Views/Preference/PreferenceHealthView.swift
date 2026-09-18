//
//  PreferenceHealthView.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

extension Preference {
    /// Health pane (design §4.4): per-signal on/off, each described in plain
    /// language. Thresholds stay fixed in v2.0 — the user chooses *whether*
    /// eul speaks, not *when* (P5).
    struct HealthView: View {
        @EnvironmentObject var healthStore: HealthStore

        private func resetToDefaults() {
            healthStore.thermalEnabled = true
            healthStore.runawayEnabled = true
            healthStore.memoryPressureEnabled = true
            healthStore.diskFullEnabled = true
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DesignTokens.Panel.spacing) {
                Settings.Card(title: "ui.health".localized()) {
                    Settings.ToggleRow(
                        title: "health.thermal".localized(),
                        caption: "health.thermal.desc".localized(),
                        isOn: $healthStore.thermalEnabled
                    )
                    Settings.RowDivider()
                    Settings.ToggleRow(
                        title: "health.runaway".localized(),
                        caption: "health.runaway.desc".localized(),
                        isOn: $healthStore.runawayEnabled
                    )
                    Settings.RowDivider()
                    Settings.ToggleRow(
                        title: "health.memory".localized(),
                        caption: "health.memory.desc".localized(),
                        isOn: $healthStore.memoryPressureEnabled
                    )
                    Settings.RowDivider()
                    Settings.ToggleRow(
                        title: "health.disk".localized(),
                        caption: "health.disk.desc".localized(),
                        isOn: $healthStore.diskFullEnabled
                    )
                }
                Settings.ResetRow(action: resetToDefaults)
            }
        }
    }
}
