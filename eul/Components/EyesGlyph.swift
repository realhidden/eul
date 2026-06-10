//
//  EyesGlyph.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// The eul mark — two eyes in a 20×12 design box. The product's one custom
/// glyph and its single health indicator (design §2.4 / §5.4):
/// normal = monochrome outline, elevated = right eye fills amber,
/// critical = both eyes fill red. Drawn with shapes so it scales crisply
/// at 18 pt (bar), 17 pt (panel header), and widget sizes.
struct EyesGlyph: View {
    enum HealthState: String {
        case normal
        case elevated
        case critical
    }

    var state: HealthState = .normal
    var width: CGFloat = 18

    /// geometry in 20×12 design units (matches the handoff SVG)
    private var unit: CGFloat {
        width / 20
    }

    private var ringRadius: CGFloat {
        4.2 * unit
    }

    private var pupilRadius: CGFloat {
        1.5 * unit
    }

    private var strokeWidth: CGFloat {
        1.5 * unit
    }

    private func eye(center: CGPoint, ringFill: Color?, ring: Color, pupil: Color) -> some View {
        ZStack {
            if let ringFill = ringFill {
                Circle()
                    .fill(ringFill)
                    .frame(width: ringRadius * 2, height: ringRadius * 2)
            }
            Circle()
                .strokeBorder(ring, lineWidth: strokeWidth)
                .frame(width: ringRadius * 2 + strokeWidth, height: ringRadius * 2 + strokeWidth)
            Circle()
                .fill(pupil)
                .frame(width: pupilRadius * 2, height: pupilRadius * 2)
        }
        .position(center)
    }

    var body: some View {
        let base = Color.primary
        ZStack {
            switch state {
            case .normal:
                eye(center: CGPoint(x: 6 * unit, y: 6 * unit), ringFill: nil, ring: base, pupil: base)
                eye(center: CGPoint(x: 14 * unit, y: 6 * unit), ringFill: nil, ring: base, pupil: base)
            case .elevated:
                eye(center: CGPoint(x: 6 * unit, y: 6 * unit), ringFill: nil, ring: base, pupil: base)
                eye(
                    center: CGPoint(x: 14 * unit, y: 6 * unit),
                    ringFill: DesignTokens.Health.elevated,
                    ring: DesignTokens.Health.elevated,
                    pupil: Color(NSColor(srgbRed: 0.165, green: 0.165, blue: 0.173, alpha: 1))
                )
            case .critical:
                eye(center: CGPoint(x: 6 * unit, y: 6 * unit), ringFill: DesignTokens.Health.critical, ring: DesignTokens.Health.critical, pupil: .white)
                eye(center: CGPoint(x: 14 * unit, y: 6 * unit), ringFill: DesignTokens.Health.critical, ring: DesignTokens.Health.critical, pupil: .white)
            }
        }
        .frame(width: width, height: width * 0.6)
    }
}
