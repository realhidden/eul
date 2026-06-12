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

    var body: some View {
        // one leaf per component, each subscribing only to the stores it
        // reads — @EnvironmentObject subscribes regardless of which switch
        // branch runs, so a shared body would invalidate every slot on
        // every store tick (and the network tick is a separate cadence)
        switch component {
        case .CPU:
            CpuSlot()
        case .Memory:
            MemorySlot()
        case .GPU:
            GpuSlot()
        case .Disk:
            DiskSlot()
        case .Battery:
            BatterySlot()
        case .Fan:
            FanSlot()
        case .Network:
            NetworkSlotContainer()
        }
    }
}

private struct CpuSlot: View {
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        SlotText(label: "CPU", value: cpuStore.usageString, worstCase: "100%", tint: healthStore.abnormalComponent == .CPU ? healthStore.level.accent : nil)
    }
}

private struct MemorySlot: View {
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        SlotText(label: "MEM", value: memoryStore.usedPercentageString, worstCase: "100%", tint: healthStore.abnormalComponent == .Memory ? healthStore.level.accent : nil)
    }
}

private struct GpuSlot: View {
    @EnvironmentObject var gpuStore: GpuStore

    var body: some View {
        SlotText(label: "GPU", value: gpuStore.usageAverageString ?? "N/A", worstCase: "100%")
    }
}

private struct DiskSlot: View {
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        SlotText(label: "DISK", value: diskStore.freeString, worstCase: "888.8 GB", tint: healthStore.abnormalComponent == .Disk ? healthStore.level.accent : nil)
    }
}

private struct BatterySlot: View {
    @EnvironmentObject var batteryStore: BatteryStore

    /// the same cue the panel tile carries, in the bar (§5.2: health colors
    /// only): charge thresholds while on battery power
    private var tint: Color? {
        guard !batteryStore.acPowered else {
            return nil
        }
        if batteryStore.charge <= 0.1 {
            return HealthLevel.critical.accent
        }
        if batteryStore.charge <= 0.2 {
            return HealthLevel.elevated.accent
        }
        return nil
    }

    var body: some View {
        SlotText(label: "BATT", value: batteryStore.charge.percentageString, worstCase: "100%", tint: tint)
    }
}

private struct FanSlot: View {
    @EnvironmentObject var fanStore: FanStore

    private var fanAverageString: String {
        let speeds = fanStore.fans.compactMap { $0.currentSpeed }
        guard speeds.count > 0 else {
            return "N/A"
        }
        return "\(speeds.reduce(0, +) / speeds.count)"
    }

    var body: some View {
        SlotText(label: "FAN", value: fanAverageString, worstCase: "8888")
    }
}

private struct NetworkSlotContainer: View {
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var preferenceStore: PreferenceStore

    var body: some View {
        NetworkSlot(
            down: ByteUnit(networkStore.inSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits),
            up: ByteUnit(networkStore.outSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits)
        )
    }
}

struct SlotText: View {
    @EnvironmentObject var preferenceStore: PreferenceStore

    let label: String
    let value: String
    let worstCase: String
    var tint: Color?

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
                    .foregroundColor(tint)
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
/// truncated to what the width governor currently allows (design §2.2 D/C).
/// Slots only — no eyes glyph next to the metrics (user feedback: it read as
/// noise and its health state was mistaken for fan state; health cues live
/// in the slot values themselves). The eyes appear exactly where they are
/// load-bearing: the anchor floor when the strip has nothing to show, and
/// the panel header. While a manual fan override is active a FAN slot
/// auto-pins ahead of the governed slots, exempt from collapse (§2.7).
struct StripView: View, SizeChangeView {
    @EnvironmentObject var componentsStore: ComponentsStore<EulComponent>
    @EnvironmentObject var fanControl: FanControlStore

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
