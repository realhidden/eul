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

    /// rail item in the panel's segmented idiom
    struct PreferenceSectionView: View {
        @Binding var activeSection: Section
        let section: Section

        var isActive: Bool {
            activeSection == section
        }

        var body: some View {
            Button(action: {
                activeSection = section
            }) {
                HStack(spacing: 8) {
                    Text(section.localizedDescription)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isActive ? Color.primary.opacity(0.12) : Color.clear)
                .cornerRadius(7)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .pointingHandCursor()
        }
    }
}
