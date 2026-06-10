//
//  PanelTiles.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// Panel tile container (design §7 Tile): label, optional aux figure, body
/// content; the abnormal variant carries the surface's only color. Tiles for
/// absent hardware are absent, never empty (§2.6).
struct PanelTile<Content: View>: View {
    var label: String
    var aux: String?
    var abnormal = false
    var minHeight: CGFloat? = 86
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(.primary.opacity(0.55))
                Spacer()
                if let aux = aux {
                    Text(aux)
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(abnormal ? DesignTokens.Health.elevated : .primary.opacity(0.55))
                }
            }
            content()
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .stroke(abnormal ? DesignTokens.Health.elevated.opacity(0.7) : Color.clear, lineWidth: 1)
        )
    }
}

/// Stacked horizontal bar; segments differentiated by opacity steps, never
/// hue — legible in both modes and to all color vision types (design §5.2)
struct SegmentBar: View {
    /// (fraction of full width, opacity)
    var segments: [(fraction: Double, opacity: Double)]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(0..<segments.count, id: \.self) { index in
                    Rectangle()
                        .fill(Color.primary.opacity(segments[index].opacity))
                        .frame(width: max(0, geometry.size.width * CGFloat(min(max(segments[index].fraction, 0), 1))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.12))
        .clipShape(Capsule())
        .padding(.top, 4)
    }
}

/// Per-core micro-columns grouped and labeled E / P (design §7 CoreGrid)
struct CoreGrid: View {
    var usages: [Double]
    var labels: [String]
    var abnormal = false

    private struct Cluster {
        let label: String
        let values: [Double]
    }

    private var clusters: [Cluster] {
        var groups: [(String, [Double])] = []
        for (index, usage) in usages.enumerated() {
            let prefix = String(labels[safe: index]?.prefix(1) ?? "C")
            if let last = groups.last, last.0 == prefix {
                groups[groups.count - 1].1.append(usage)
            } else {
                groups.append((prefix, [usage]))
            }
        }
        return groups.map { Cluster(label: $0.0, values: $0.1) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            ForEach(0..<clusters.count, id: \.self) { clusterIndex in
                HStack(alignment: .bottom, spacing: 4) {
                    Text(clusters[clusterIndex].label)
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.primary.opacity(0.35))
                    ForEach(0..<clusters[clusterIndex].values.count, id: \.self) { coreIndex in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(abnormal ? DesignTokens.Health.elevated : Color.primary.opacity(0.85))
                                .frame(height: 30 * CGFloat(min(max(clusters[clusterIndex].values[coreIndex] / 100, 0), 1)))
                        }
                        .frame(width: 9, height: 30)
                    }
                }
            }
        }
    }
}

/// Process row (design §7 ProcessRow): app icon, name, tabular value
struct PanelProcessRow: View {
    var icon: NSImage?
    var name: String
    var value: String

    var body: some View {
        HStack(spacing: 9) {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 19, height: 19)
                    .cornerRadius(5)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 19, height: 19)
                    .overlay(
                        Text(String(name.prefix(1)).uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.primary.opacity(0.8))
                    )
            }
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(value)
                .font(Font.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .padding(.vertical, 6)
    }
}
