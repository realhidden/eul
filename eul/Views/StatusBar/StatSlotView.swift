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
/// Lets a subtree render slots in a style other than the stored one, so
/// Settings can show all three at once against live data. Nil everywhere
/// except that preview, where reading the real preference would defeat it.
private struct SlotStyleOverrideKey: EnvironmentKey {
    static let defaultValue: Preference.slotStyle? = nil
}

extension EnvironmentValues {
    var slotStyleOverride: Preference.slotStyle? {
        get { self[SlotStyleOverrideKey.self] }
        set { self[SlotStyleOverrideKey.self] = newValue }
    }
}

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
        SlotText(
            label: "CPU",
            value: cpuStore.usageString,
            worstCase: "100%",
            tint: healthStore.abnormalComponent == .CPU ? healthStore.level.accent : nil,
            component: .CPU,
            history: healthStore.cpuHistory
        )
    }
}

private struct MemorySlot: View {
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        SlotText(
            label: "MEM",
            value: memoryStore.usedPercentageString,
            worstCase: "100%",
            tint: healthStore.abnormalComponent == .Memory ? healthStore.level.accent : nil,
            component: .Memory,
            history: healthStore.memoryHistory
        )
    }
}

private struct GpuSlot: View {
    @EnvironmentObject var gpuStore: GpuStore
    @EnvironmentObject var healthStore: HealthStore

    var body: some View {
        SlotText(
            label: "GPU",
            value: gpuStore.usageAverageString ?? "N/A",
            worstCase: "100%",
            component: .GPU,
            history: healthStore.gpuHistory
        )
    }
}

private struct DiskSlot: View {
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var healthStore: HealthStore

    /// used share of the selected volume — a ceiling makes a level bar truer
    /// than a history trace here (free space barely moves minute to minute)
    private var used: Double? {
        guard let ceiling = diskStore.ceilingBytes, ceiling > 0, let free = diskStore.freeBytes else {
            return nil
        }
        return Double(ceiling - free) / Double(ceiling)
    }

    var body: some View {
        SlotText(
            label: "DISK",
            value: diskStore.freeString,
            worstCase: "888.8 GB",
            tint: healthStore.abnormalComponent == .Disk ? healthStore.level.accent : nil,
            component: .Disk,
            level: used
        )
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
        SlotText(
            label: "BATT",
            value: batteryStore.charge.percentageString,
            worstCase: "100%",
            tint: tint,
            component: .Battery,
            level: batteryStore.charge
        )
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
        SlotText(label: "FAN", value: fanAverageString, worstCase: "8888", component: .Fan)
    }
}

private struct NetworkSlotContainer: View {
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var healthStore: HealthStore
    @Environment(\.slotStyleOverride) private var styleOverride

    var body: some View {
        let inBits = preferenceStore.networkRateInBits
        if (styleOverride ?? preferenceStore.slotStyle) == .smart {
            // one line instead of two: the smart style spends the height it
            // saves on the history chart, which is the point of the style
            SmartNetworkSlot(
                down: ByteUnit(networkStore.inSpeedInByte).readableParts(inBits: inBits),
                up: ByteUnit(networkStore.outSpeedInByte).readableParts(inBits: inBits),
                history: healthStore.networkHistory
            )
        } else {
            NetworkSlot(
                down: ByteUnit(networkStore.inSpeedInByte).readableRate(inBits: inBits),
                up: ByteUnit(networkStore.outSpeedInByte).readableRate(inBits: inBits)
            )
        }
    }
}

/// Smart-style network: the paired-arrows glyph, both rates on one line, and
/// the throughput history underneath. Each rate keeps its own magnitude
/// letter (95K/722K) — down and up routinely sit in different units, and a
/// forced shared unit would render one of them as 0.
struct SmartNetworkSlot: View {
    let down: (value: String, unit: String)
    let up: (value: String, unit: String)
    let history: [Double]

    private static let worstCase = "888.8M/888.8M"

    private func compact(_ parts: (value: String, unit: String)) -> String {
        parts.value + String(parts.unit.prefix(1))
    }

    private var columnWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        return ceil((Self.worstCase as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                ComponentGlyph(component: .Network)
                ZStack(alignment: .trailing) {
                    Text(Self.worstCase).hidden()
                    Text("\(compact(down))/\(compact(up))")
                }
                .font(DesignTokens.Typo.slotValue)
            }
            MicroBars(values: history, width: columnWidth)
        }
    }
}

/// The smart style's history strip: a row of micro bars under a slot value.
///
/// Normalised against the window's OWN range, not the metric's ceiling. A
/// 0–100 scale looks correct and is useless: a CPU sitting at 87% draws every
/// bar at 87% height, i.e. a uniform comb. The number above already carries
/// the level — the chart's job is to show movement, so the window's min..max
/// is the scale that earns its 5 pt.
struct MicroBars: View {
    let values: [Double]
    /// matches the value column so the chart never widens the slot
    let width: CGFloat

    private static let barWidth: CGFloat = 1.5
    private static let gap: CGFloat = 1.2
    private static let height: CGFloat = 5
    /// a flat window still draws this, so idle reads as a baseline instead of
    /// vanishing into the menu bar
    private static let floor: CGFloat = 1

    var body: some View {
        let slots = max(Int((width + Self.gap) / (Self.barWidth + Self.gap)), 1)
        let window = Array(values.suffix(slots))
        let top = window.max() ?? 0
        let bottom = window.min() ?? 0
        let span = top - bottom
        return HStack(alignment: .bottom, spacing: Self.gap) {
            ForEach(0..<window.count, id: \.self) { index in
                let level = span > 0 ? (window[index] - bottom) / span : 0
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.primary.opacity(0.4))
                    .frame(
                        width: Self.barWidth,
                        height: Self.floor + CGFloat(level) * (Self.height - Self.floor)
                    )
            }
        }
        .frame(width: width, height: Self.height, alignment: .trailing)
    }
}

/// The smart style's level bar: for readings with a meaningful ceiling
/// (disk used, battery charge) a fill reads truer than a history trace.
struct MicroLevel: View {
    /// 0...1
    let fraction: Double
    let width: CGFloat

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.18))
            Capsule()
                .fill(Color.primary.opacity(0.5))
                .frame(width: width * CGFloat(clamped))
        }
        .frame(width: width, height: 3)
    }
}

struct SlotText: View {
    @EnvironmentObject var preferenceStore: PreferenceStore
    @Environment(\.slotStyleOverride) private var styleOverride

    let label: String
    let value: String
    let worstCase: String
    var tint: Color?
    /// smart style: the component whose template glyph replaces the label
    var component: EulComponent?
    /// smart style: recent samples for the chart, oldest first
    var history: [Double] = []
    /// smart style: 0...1 level, used where a ceiling is meaningful
    var level: Double?

    /// the value column reserves its worst case, so the trace underneath can
    /// be measured off the same string instead of a second layout pass
    private var columnWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        return ceil((worstCase as NSString).size(withAttributes: [.font: font]).width)
    }

    private var valueColumn: some View {
        ZStack(alignment: .trailing) {
            Text(worstCase).hidden()
            Text(value)
                .foregroundColor(tint)
        }
        .font(DesignTokens.Typo.slotValue)
    }

    /// glyph and value share a row so the icon sits BESIDE the number; the
    /// chart hangs under the value column only, right-aligned to it. Centring
    /// the glyph against the whole stack instead drops it below the number
    /// and reads as misalignment.
    private var smartBody: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 3) {
                if let component = component {
                    ComponentGlyph(component: component)
                }
                valueColumn
            }
            if let level = level {
                MicroLevel(fraction: level, width: columnWidth)
            } else if history.count > 1 {
                MicroBars(values: history, width: columnWidth)
            }
        }
    }

    var body: some View {
        switch styleOverride ?? preferenceStore.slotStyle {
        case .full:
            HStack(spacing: 5) {
                Text(label)
                    .font(DesignTokens.Typo.slotLabel)
                    .tracking(0.6)
                    .opacity(0.55)
                valueColumn
            }
        case .valueOnly:
            valueColumn
        case .smart:
            smartBody
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
