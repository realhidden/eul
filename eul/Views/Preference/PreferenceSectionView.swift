//
//  PreferenceSectionView.swift
//  eul
//
//  Created by Gao Sun on 2020/10/24.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

extension Preference {
    /// the three panes of the settings rebuild (design §4.4): General /
    /// Menu Bar / Health — rare decisions, no assembly
    enum Section: String, Identifiable, CaseIterable {
        case general
        case components
        case health

        var id: String {
            rawValue
        }

        var localizedDescription: String {
            switch self {
            case .general:
                return "ui.general".localized()
            case .components:
                return "ui.menu_bar".localized()
            case .health:
                return "ui.health".localized()
            }
        }
    }

    struct PreferenceSectionView: View {
        @Binding var activeSection: Section
        let section: Section

        var isActive: Bool {
            activeSection == section
        }

        var body: some View {
            HStack(spacing: 8) {
                Text(section.localizedDescription)
                    .inlineSection()
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isActive ? Color.separator : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onTapGesture {
                activeSection = section
            }
        }
    }
}
