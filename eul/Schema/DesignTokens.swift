//
//  DesignTokens.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// eul 2.0 design tokens — single source of truth, mirroring the design
/// direction document (design/handoff/project, §5) and the prototype's
/// `T` constants. Health colors are sRGB conversions of the OKLCH tokens;
/// per §5.2 they are the only color in the product.
enum DesignTokens {
    enum Health {
        /// amber — something deserves a look when convenient (right eye fills)
        /// oklch(0.70 0.145 75) light / oklch(0.78 0.145 80) dark
        static let elevated = dynamicColor(
            light: NSColor(srgbRed: 0.8235, green: 0.5608, blue: 0.0549, alpha: 1),
            dark: NSColor(srgbRed: 0.9059, green: 0.6745, blue: 0.2078, alpha: 1)
        )
        /// red — act soon (both eyes fill)
        /// oklch(0.55 0.19 27) light / oklch(0.64 0.19 27) dark
        static let critical = dynamicColor(
            light: NSColor(srgbRed: 0.7882, green: 0.1882, blue: 0.1765, alpha: 1),
            dark: NSColor(srgbRed: 0.9137, green: 0.3137, blue: 0.2824, alpha: 1)
        )
    }

    /// §5.5 — structural motion (panel open, tile expand) plus, in the panel
    /// only, value-update motion: numbers roll, bars/sparklines tween, text
    /// cross-dissolves. The panel is mounted transiently, so this costs power
    /// only while the user is looking; the always-on bar and the widgets still
    /// re-render at the refresh cadence with no tweening. All value-update
    /// motion is gated by Reduce Motion (see `Motion`).
    enum Timing {
        static let panelOpen: TimeInterval = 0.18
        static let tileExpand: TimeInterval = 0.16
        /// a hero/mid number counting to its new value
        static let valueRoll: TimeInterval = 0.24
        /// a non-numeric figure cross-dissolving
        static let valueCrossfade: TimeInterval = 0.2
    }

    enum Panel {
        static let width: CGFloat = 360
        static let cornerRadius: CGFloat = 16
        static let tileRadius: CGFloat = 11
        static let spacing: CGFloat = 8
        static let padding: CGFloat = 14
    }

    /// §5.1 type scale — system font throughout, numerals always tabular
    enum Typo {
        /// bar slot label (9 pt caps, semibold, +6% tracking)
        static let slotLabel = Font.system(size: 9, weight: .semibold)
        /// bar slot value (12 pt medium, tabular)
        static let slotValue = Font.system(size: 12, weight: .medium).monospacedDigit()
        /// panel hero value (25–26 pt semibold)
        static let hero = Font.system(size: 25, weight: .semibold).monospacedDigit()
        /// panel mid value (13 pt semibold, two-row tiles)
        static let mid = Font.system(size: 13, weight: .semibold).monospacedDigit()
        /// panel tile label (9.5 pt ≈ 10, caps, semibold)
        static let tileLabel = Font.system(size: 10, weight: .semibold)
        /// panel aux / sub text (10.5 pt ≈ 10.5)
        static let sub = Font.system(size: 10.5).monospacedDigit()
        /// panel body (13 pt regular)
        static let body = Font.system(size: 13)
    }

    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
