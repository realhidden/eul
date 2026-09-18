//
//  ProgressBarView.swift
//  eul
//
//  Created by Gao Sun on 2020/9/20.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

public struct ProgressBarView: View {
    public init(width: CGFloat = 80, percentage: CGFloat = 100, showText: Bool = true, textWidth: CGFloat = 40, customText: String? = nil) {
        self.width = width
        self.percentage = percentage
        self.showText = showText
        self.textWidth = textWidth
        self.customText = customText
    }

    @State var firstAppear = true
    public var width: CGFloat = 80
    public var percentage: CGFloat = 100
    public var showText = true
    public var textWidth: CGFloat = 40
    public var customText: String?

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: width, height: 4)
                    .foregroundColor(.controlBackground)
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: width * percentage / 100, height: 4)
                    .foregroundColor(.primary)
            }
            if showText {
                Text(customText.map { $0 } ?? String(format: "%.1f%%", percentage))
                    .displayText()
                    .frame(width: textWidth, alignment: .trailing)
            }
        }
        .onAppear {
            self.firstAppear = false
        }
    }
}

/// The histogram the bar and panel both draw, at widget scale.
///
/// Zero-based: scaling from the window's own minimum makes an idle metric
/// draw a full-height chart, contradicting the hero number beside it. The top
/// adapts to the window so movement still shows, capped by `ceiling` where the
/// metric has one. A flat window draws the floor, so idle reads as a baseline.
public struct WidgetBars: View {
    public init(values: [Double], ceiling: Double? = nil, color: Color = .primary, barWidth: CGFloat = 4, gap: CGFloat = 2.5) {
        self.values = values
        self.ceiling = ceiling
        self.color = color
        self.barWidth = barWidth
        self.gap = gap
    }

    public var values: [Double]
    /// natural maximum, when the metric has one (100 for percentages)
    public var ceiling: Double?
    public var color: Color
    public var barWidth: CGFloat
    public var gap: CGFloat

    private static let floor: CGFloat = 2

    public var body: some View {
        GeometryReader { geometry in
            let slots = max(Int((geometry.size.width + gap) / (barWidth + gap)), 1)
            let window = Array(values.suffix(slots))
            let peak = window.max() ?? 0
            let top: Double = ceiling.map { min(max(peak * 1.1, $0 * 0.08), $0) } ?? max(peak * 1.1, .leastNonzeroMagnitude)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<window.count, id: \.self) { index in
                    let level = top > 0 ? min(max(window[index] / top, 0), 1) : 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.5))
                        .frame(
                            width: barWidth,
                            height: Self.floor + CGFloat(level) * max(geometry.size.height - Self.floor, 0)
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
    }
}
