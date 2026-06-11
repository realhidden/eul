//
//  ContentView.swift
//  eul
//
//  Created by Gao Sun on 2020/6/21.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

/// The Settings window (design §4.4): a rail of three panes and tile-style
/// cards, in the panel's design language. Rare decisions, no assembly (P5).
struct ContentView: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var healthStore: HealthStore
    @EnvironmentObject var uiStore: UIStore

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                EyesGlyph(state: healthStore.glyphState, width: 16)
                Text("eul")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            ForEach(Preference.Section.allCases) {
                Preference.PreferenceSectionView(activeSection: $uiStore.activeSection, section: $0)
            }
            Spacer()
            if let version = preferenceStore.version {
                Text("\("ui.version".localized()) \(version)")
                    .font(.system(size: 10))
                    .foregroundColor(Settings.secondary)
                    .padding(.horizontal, 10)
            }
        }
        // top padding clears the transparent title bar's traffic lights
        .padding(EdgeInsets(top: 40, leading: 10, bottom: 14, trailing: 10))
        .frame(width: 148)
        .background(Color.primary.opacity(0.03))
    }

    private var activePane: some View {
        Group {
            if uiStore.activeSection == .general {
                Preference.GeneralView()
            }
            if uiStore.activeSection == .components {
                Preference.ComponentsView()
            }
            if uiStore.activeSection == .health {
                Preference.HealthView()
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(width: 1)
            ScrollView([.vertical], showsIndicators: false) {
                VStack(alignment: .leading, spacing: DesignTokens.Panel.spacing) {
                    activePane
                }
                .padding(EdgeInsets(top: 36, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 580, height: 520)
        .id(preferenceStore.language)
        .preferredColorScheme()
    }
}
