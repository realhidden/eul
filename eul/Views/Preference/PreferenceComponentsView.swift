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
                            ComponentGlyph(component: component, size: 12, opacity: 0.75)
                            Text(component.localizedDescription)
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    Text("menu_bar.priority_note".localized())
                        .font(.system(size: 10.5))
                        .foregroundColor(Settings.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Settings.RowDivider()
                    Settings.Row(
                        title: "settings.slot_style".localized(),
                        caption: "settings.slot_style.desc".localized()
                    ) {
                        Picker("", selection: $preference.slotStyle) {
                            ForEach(Preference.slotStyle.allCases) {
                                // the tag must carry the selection's own type;
                                // StringEnum's id is a String, so relying on
                                // ForEach's implicit tag leaves the popup blank
                                Text($0.description)
                                    .tag($0)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 150)
                    }
                    slotStylePreview
                }
            }
        }

        /// The three styles rendered side by side against LIVE data, so the
        /// choice is made by looking rather than by reading three labels and
        /// guessing. Each row forces its own style through the environment;
        /// the selected one is marked so the list doubles as a legend.
        private var slotStylePreview: some View {
            VStack(alignment: .leading, spacing: 7) {
                Text("settings.slot_style.preview".localized().uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(Settings.secondary)
                ForEach(Preference.slotStyle.allCases) { style in
                    HStack(alignment: .center, spacing: 10) {
                        Text(style.description)
                            .font(.system(size: 10, weight: preference.slotStyle == style ? .semibold : .regular))
                            .foregroundColor(preference.slotStyle == style ? .primary : Settings.secondary)
                            .frame(width: 66, alignment: .leading)
                        HStack(spacing: 10) {
                            ForEach(componentsStore.activeComponents.prefix(4)) {
                                StatSlotView(component: $0)
                            }
                        }
                        .environment(\.slotStyleOverride, style)
                        .frame(height: 22)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(preference.slotStyle == style ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        preference.slotStyle = style
                    }
                    .pointingHandCursor()
                }
            }
            .padding(EdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.05))
            )
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
            preference.slotStyle = .full
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
