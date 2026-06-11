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

        private func row(isOn: Binding<Bool>, titleKey: String, descriptionKey: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: isOn) {
                    Text(titleKey.localized())
                        .inlineSection()
                }
                Text(descriptionKey.localized())
                    .secondaryDisplayText()
                    .padding(.leading, 18)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                row(isOn: $healthStore.thermalEnabled, titleKey: "health.thermal", descriptionKey: "health.thermal.desc")
                row(isOn: $healthStore.runawayEnabled, titleKey: "health.runaway", descriptionKey: "health.runaway.desc")
                row(isOn: $healthStore.memoryPressureEnabled, titleKey: "health.memory", descriptionKey: "health.memory.desc")
                row(isOn: $healthStore.diskFullEnabled, titleKey: "health.disk", descriptionKey: "health.disk.desc")
            }
            .padding(.vertical, 8)
        }
    }
}
