//
//  Sparkline.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// History ring buffer behind every sparkline (design §10 ask 1):
/// 10 minutes at the refresh cadence, in-memory only, capped sample count.
struct HistoryBuffer {
    static let maxSamples = 300

    private(set) var values: [Double] = []

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > Self.maxSamples {
            values.removeFirst(values.count - Self.maxSamples)
        }
    }
}

/// Monochrome line + 12% fill, no tweening, truncates at the last real
/// sample (design §7 Sparkline). Points append at the refresh cadence —
/// the view never animates between them (§5.5).
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double
    var color: Color = .primary

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, maxValue > 0 else {
            return []
        }
        let stepX = size.width / CGFloat(values.count - 1)
        // top 2pt of headroom like the prototype (24/26 of height used)
        let usable = size.height - 2
        return values.enumerated().map { index, value in
            let clamped = CGFloat(min(max(value, 0), maxValue) / maxValue)
            return CGPoint(x: CGFloat(index) * stepX, y: size.height - usable * clamped)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let pts = points(in: geometry.size)
            if pts.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height))
                        pts.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                    Path { path in
                        path.move(to: pts[0])
                        pts.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
