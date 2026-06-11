//
//  StatSlotView.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

/// One strip slot (design §2.3 / §7 StatSlot): 9 pt caps label + 12 pt medium
/// tabular value, fixed-width by the monitor's worst case so a value changing
/// digit count never moves its neighbors. Labels are technical abbreviations
/// (CPU, MEM…), deliberately unlocalized like unit symbols. The value-only
/// toggle (design §4.7, dense-bar story) drops the labels — one decision,
/// not a layout editor.
struct StatSlotView: View {
    let component: EulComponent

    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var gpuStore: GpuStore
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var batteryStore: BatteryStore
    @EnvironmentObject var fanStore: FanStore
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var preferenceStore: PreferenceStore

    private var fanAverageString: String {
        let speeds = fanStore.fans.compactMap { $0.currentSpeed }
        guard speeds.count > 0 else {
            return "N/A"
        }
        return "\(speeds.reduce(0, +) / speeds.count)"
    }

    var body: some View {
        switch component {
        case .CPU:
            SlotText(label: "CPU", value: cpuStore.usageString, worstCase: "100%")
        case .Memory:
            SlotText(label: "MEM", value: memoryStore.usedPercentageString, worstCase: "100%")
        case .GPU:
            SlotText(label: "GPU", value: gpuStore.usageAverageString ?? "N/A", worstCase: "100%")
        case .Disk:
            SlotText(label: "DISK", value: diskStore.freeString, worstCase: "888.8 GB")
        case .Battery:
            SlotText(label: "BATT", value: batteryStore.charge.percentageString, worstCase: "100%")
        case .Fan:
            SlotText(label: "FAN", value: fanAverageString, worstCase: "8888")
        case .Network:
            NetworkSlot(
                down: ByteUnit(networkStore.inSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits),
                up: ByteUnit(networkStore.outSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits)
            )
        }
    }
}

struct SlotText: View {
    @EnvironmentObject var preferenceStore: PreferenceStore

    let label: String
    let value: String
    let worstCase: String

    var body: some View {
        HStack(spacing: 5) {
            if !preferenceStore.valueOnlySlots {
                Text(label)
                    .font(DesignTokens.Typo.slotLabel)
                    .tracking(0.6)
                    .opacity(0.55)
            }
            ZStack(alignment: .trailing) {
                Text(worstCase).hidden()
                Text(value)
            }
            .font(DesignTokens.Typo.slotValue)
        }
    }
}

/// Two stacked ↓/↑ rows (design §7 DeltaPair); arrows are semantic and
/// RTL-safe, value column right-aligned with reserved width
struct NetworkSlot: View {
    let down: String
    let up: String

    private func row(_ arrow: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(arrow)
                .font(.system(size: 8))
                .opacity(0.5)
            ZStack(alignment: .trailing) {
                Text("888.8 MB/s").hidden()
                Text(value)
            }
        }
        .font(Font.system(size: 8.5, weight: .medium).monospacedDigit())
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            row("↓", down)
            row("↑", up)
        }
    }
}

/// The strip's whole content: the user's pinned monitors in priority order,
/// truncated to what the width governor currently allows (design §2.2 D/C),
/// with the eyes glyph at the trailing (clock-side) end — slots and identity
/// are ONE menu bar item, one entry point (user feedback: two icons read as
/// two separate apps). The standalone anchor item appears only when this
/// strip is hidden. While a manual fan override is active a FAN slot
/// auto-pins ahead of the governed slots, exempt from collapse (§2.7).
struct StripView: View, SizeChangeView {
    @EnvironmentObject var componentsStore: ComponentsStore<EulComponent>
    @EnvironmentObject var fanControl: FanControlStore
    @EnvironmentObject var healthStore: HealthStore

    var onSizeChange: ((CGSize) -> Void)?
    let slotLimit: Int

    var slots: [EulComponent] {
        var pinned = Array(componentsStore.activeComponents.prefix(slotLimit))
        if fanControl.overrideActive {
            pinned.removeAll { $0 == .Fan }
        }
        return pinned
    }

    var body: some View {
        HStack(spacing: 10) {
            if fanControl.overrideActive {
                StatSlotView(component: .Fan)
            }
            ForEach(slots) {
                StatSlotView(component: $0)
            }
            EyesGlyph(state: healthStore.glyphState, width: AnchorStatusItem.glyphWidth)
        }
        .frame(height: AppDelegate.statusBarHeight)
        .fixedSize()
        .background(GeometryReader { self.reportSize($0) })
        .onPreferenceChange(SizePreferenceKey.self) { value in
            if let size = value.first {
                self.onSizeChange?(size)
            }
        }
        .allowsHitTesting(false)
    }
}
