//
//  PreferenceComponentsView.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

extension Preference {
    /// The Menu Bar pane (design §4.4): pinned monitors with drag-to-set
    /// priority, the fixed tight-space behavior explained (not configurable),
    /// the value-only density toggle (§4.7), and the two data-source choices.
    /// The anchor is always shown — presence is the contract (P2), so it is
    /// deliberately not a setting.
    struct ComponentsView: View {
        @EnvironmentObject var componentsStore: ComponentsStore<EulComponent>
        @EnvironmentObject var componentConfigStore: ComponentConfigStore
        @EnvironmentObject var diskStore: DiskStore
        @EnvironmentObject var networkStore: NetworkStore
        @EnvironmentObject var preference: PreferenceStore

        var diskConfig: Binding<EulComponentConfig> {
            $componentConfigStore[EulComponent.Disk]
        }

        var networkConfig: Binding<EulComponentConfig> {
            $componentConfigStore[EulComponent.Network]
        }

        private var pinnedCard: some View {
            Settings.Card(title: "ui.menu_bar".localized()) {
                Settings.ToggleRow(
                    title: "ui.show_components_in_status_bar".localized(),
                    caption: "menu_bar.anchor_note".localized(),
                    isOn: $componentsStore.showComponents
                )
                if componentsStore.showComponents {
                    Settings.RowDivider()
                    HorizontalOrganizingView(componentsStore: componentsStore) { component in
                        HStack(spacing: 6) {
                            Image(component.rawValue)
                                .resizable()
                                .frame(width: 12, height: 12)
                            Text(component.localizedDescription)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    Text("menu_bar.priority_note".localized())
                        .font(.system(size: 10.5))
                        .foregroundColor(Settings.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Settings.RowDivider()
                    Settings.ToggleRow(
                        title: "settings.value_only".localized(),
                        caption: "settings.value_only.desc".localized(),
                        isOn: $preference.valueOnlySlots
                    )
                }
            }
        }

        private var dataSourcesCard: some View {
            Settings.Card(title: "ui.data_sources".localized()) {
                if let disks = diskStore.list?.disks {
                    Settings.Row(title: "disk.select".localized()) {
                        Picker("", selection: diskConfig.diskSelection) {
                            // empty selection = boot volume (#250/#182),
                            // not a sum of all volumes
                            Text("disk.boot_volume".localized())
                                .tag("")
                            ForEach(disks) {
                                Text($0.name)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 170)
                    }
                    Settings.RowDivider()
                }
                Settings.Row(title: "network.port.select".localized()) {
                    Picker("", selection: networkConfig.networkPortSelection) {
                        Text(networkStore.autoPortDesscription)
                            .tag("")
                        ForEach(networkStore.ports) {
                            Text($0.description)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 170)
                }
            }
        }

        private func resetToDefaults() {
            componentsStore.resetToDefaults()
            preference.valueOnlySlots = false
            componentConfigStore[EulComponent.Disk].diskSelection = ""
            componentConfigStore[EulComponent.Network].networkPortSelection = ""
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DesignTokens.Panel.spacing) {
                pinnedCard
                dataSourcesCard
                Settings.ResetRow(action: resetToDefaults)
            }
            .onAppear {
                // the volume list is otherwise populated only while a
                // Disk slot is pinned or the panel is open
                diskStore.loadDisks()
            }
        }
    }
}
