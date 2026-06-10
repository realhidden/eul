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
    /// and the two data-source choices (boot volume / network interface).
    /// The anchor is always shown — presence is the contract (P2), so it is
    /// deliberately not a setting.
    struct ComponentsView: View {
        @EnvironmentObject var componentsStore: ComponentsStore<EulComponent>
        @EnvironmentObject var componentConfigStore: ComponentConfigStore
        @EnvironmentObject var diskStore: DiskStore
        @EnvironmentObject var networkStore: NetworkStore

        var diskConfig: Binding<EulComponentConfig> {
            $componentConfigStore[EulComponent.Disk]
        }

        var networkConfig: Binding<EulComponentConfig> {
            $componentConfigStore[EulComponent.Network]
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Toggle(isOn: $componentsStore.showComponents) {
                        Text("ui.show_components_in_status_bar".localized())
                            .inlineSection()
                    }
                    Spacer()
                }
                if componentsStore.showComponents {
                    HorizontalOrganizingView(
                        componentsStore: componentsStore,
                        title: "component.status_bar"
                    ) { component in
                        HStack {
                            Image(component.rawValue)
                                .resizable()
                                .frame(width: 12, height: 12)
                            Text(component.localizedDescription)
                                .normal()
                        }
                    }
                    Text("menu_bar.priority_note".localized())
                        .secondaryDisplayText()
                        .padding(.top, 4)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("ui.data_sources".localized())
                        .subsection()
                    HStack(spacing: 12) {
                        if let disks = diskStore.list?.disks {
                            Picker(
                                "disk.select".localized(),
                                selection: diskConfig.diskSelection
                            ) {
                                // empty selection = boot volume (#250/#182),
                                // not a sum of all volumes
                                Text("disk.boot_volume".localized())
                                    .inlineSection()
                                    .tag("")
                                ForEach(disks) {
                                    Text($0.name)
                                        .inlineSection()
                                }
                            }
                            .frame(width: 200)
                        }
                        Picker(
                            "network.port.select".localized(),
                            selection: networkConfig.networkPortSelection
                        ) {
                            Text(networkStore.autoPortDesscription)
                                .inlineSection()
                                .tag("")
                            ForEach(networkStore.ports) {
                                Text($0.description)
                                    .inlineSection()
                            }
                        }
                        .fixedSize()
                    }
                }
                .padding(.top, 16)
                .onAppear {
                    // the volume list is otherwise populated only while a
                    // Disk slot is pinned or the panel is open
                    diskStore.loadDisks()
                }
            }
        }
    }
}
