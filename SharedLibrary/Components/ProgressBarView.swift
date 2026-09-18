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
/// Normalised against the window's own range rather than the metric's
/// ceiling: the hero number already carries the level, so the chart's job is
/// to show movement. A flat window still draws the floor, so an idle stretch
/// reads as a baseline instead of an empty card.
public struct WidgetBars: View {
    public init(values: [Double], color: Color = .primary, barWidth: CGFloat = 4, gap: CGFloat = 2.5) {
        self.values = values
        self.color = color
        self.barWidth = barWidth
        self.gap = gap
    }

    public var values: [Double]
    public var color: Color
    public var barWidth: CGFloat
    public var gap: CGFloat

    private static let floor: CGFloat = 2

    public var body: some View {
        GeometryReader { geometry in
            let slots = max(Int((geometry.size.width + gap) / (barWidth + gap)), 1)
            let window = Array(values.suffix(slots))
            let top = window.max() ?? 0
            let bottom = window.min() ?? 0
            let span = top - bottom
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<window.count, id: \.self) { index in
                    let level = span > 0 ? (window[index] - bottom) / span : 0
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
