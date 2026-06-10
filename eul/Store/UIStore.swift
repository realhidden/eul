//
//  UIStore.swift
//  eul
//
//  Created by Gao Sun on 2020/10/17.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import AppKit
import Foundation

class UIStore: ObservableObject {
    /// the panel's process-list lens; the matching collector runs only while
    /// the panel is open AND its lens is selected (open-only contract, §2.6)
    enum ProcLens: String, CaseIterable, Identifiable {
        case cpu
        case memory
        case network

        var id: String {
            rawValue
        }

        var localizedDescription: String {
            "component.\(rawValue)".localized()
        }
    }

    @Published var hoveringID: String?
    @Published var menuWidth: CGFloat?
    /// historically "menu open"; now means "panel open" — the expensive
    /// collectors and gated stores key off it unchanged
    @Published var menuOpened = false
    @Published var activeSection: Preference.Section = .general
    @Published var panelLens: ProcLens = .cpu
}
