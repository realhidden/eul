//
//  PanelRemoteView.swift
//  eul
//
//  Created by Zsombor Paróczi on 2026/9/25.
//  Copyright © 2026 Zsombor Paróczi. All rights reserved.
//

import SharedLibrary
import SwiftUI

/// The panel's tile grid for a peer picked in the footer: the same tiles as
/// the local grid, fed from the peer's last snapshot. No processes — a Mac
/// only samples those while its own panel is open. Sections a 2.2 peer does
/// not send (cores, memory breakdown, disk) are left out.
struct PanelRemoteTiles: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    let peer: PeerDiscoveryStore.Peer

    private var secondary: Color {
        Color.primary.opacity(0.55)
    }

    private var stats: PeerDiscoveryStore.Stats {
        peer.stats
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    private var cpuTile: some View {
        PanelTile(
            label: "component.cpu".localized().uppercased(),
            glyph: .CPU,
            aux: stats.temperature(in: preferenceStore.temperatureUnit)?.temperatureString
        ) {
            RollingNumber(stats.cpu, format: percent)
                .font(DesignTokens.Typo.hero)
            PanelBars(values: peer.cpuHistory, ceiling: 100)
                .frame(height: 22)
                .padding(.top, 2)
            if let cores = stats.cores {
                Text(String(format: "panel.cores".localized(), cores.count))
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.top, 2)
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 1)
                    .padding(.top, 6)
                CoreGrid(
                    usages: cores.map(Double.init),
                    labels: (stats.coreKinds ?? "").map(String.init),
                    accent: nil
                )
                .padding(.top, 8)
            }
        }
    }

    private var memoryTile: some View {
        PanelTile(label: "component.memory".localized().uppercased(), glyph: .Memory) {
            RollingNumber(stats.memory, format: percent)
                .font(DesignTokens.Typo.hero)
            if
                let total = stats.memoryTotal, total > 0,
                let app = stats.memoryApp, let wired = stats.memoryWired, let compressed = stats.memoryCompressed
            {
                SegmentBar(segments: [(app / total, 0.95), (wired / total, 0.5), (compressed / total, 0.28)])
                Text(String(
                    format: "%@ %.1f · %@ %.1f · %@ %.1f GB",
                    "memory.app".localized(), app,
                    "memory.wired".localized(), wired,
                    "memory.compressed".localized(), compressed
                ))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
            PanelBars(values: peer.memoryHistory, ceiling: 100)
                .frame(height: 16)
                .padding(.top, 3)
        }
    }

    private func rateRow(_ arrow: String, _ bytesPerSecond: Double) -> some View {
        let parts = ByteUnit(bytesPerSecond).readableParts(inBits: preferenceStore.networkRateInBits)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(arrow).foregroundColor(secondary).font(.system(size: 11))
            Text(parts.value).font(DesignTokens.Typo.mid)
            Text("\(parts.unit)/s")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(secondary)
        }
    }

    private var networkTile: some View {
        PanelTile(label: "component.network".localized().uppercased(), glyph: .Network) {
            rateRow("↓", stats.networkIn)
            rateRow("↑", stats.networkOut)
            PanelBars(values: peer.networkHistory)
                .frame(height: 22)
                .padding(.top, 2)
        }
    }

    private var gpuTile: some View {
        PanelTile(label: "component.gpu".localized().uppercased(), glyph: .GPU) {
            RollingNumber(stats.gpu, format: percent)
                .font(DesignTokens.Typo.hero)
            PanelBars(values: peer.gpuHistory, ceiling: 100)
                .frame(height: 16)
                .padding(.top, 3)
        }
    }

    private func diskTile(free: UInt64, total: UInt64) -> some View {
        PanelTile(
            label: "component.disk".localized().uppercased(),
            glyph: .Disk,
            aux: (Double(total - min(free, total)) / Double(total)).percentageString
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ByteUnit(Double(free), kilo: 1000).readable)
                    .font(Font.system(size: 19, weight: .semibold).monospacedDigit())
                Text("text_component.free".localized().lowercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondary)
            }
            SegmentBar(segments: [(Double(total - min(free, total)) / Double(total), 0.95)])
            Text(String(format: "panel.of".localized(), ByteUnit(Double(total), kilo: 1000).readable))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
        }
    }

    var body: some View {
        VStack(spacing: DesignTokens.Panel.spacing) {
            cpuTile
            HStack(alignment: .top, spacing: DesignTokens.Panel.spacing) {
                memoryTile
                networkTile
            }
            HStack(alignment: .top, spacing: DesignTokens.Panel.spacing) {
                gpuTile
                if let free = stats.diskFree, let total = stats.diskTotal, total > 0 {
                    diskTile(free: free, total: total)
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }
}
