//
//  PanelView.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SharedLibrary
import SwiftUI

/// eul's own footprint, reported on every panel open — energy honesty as a
/// feature (design §2.6 footer)
private final class SelfUsageSampler: ObservableObject {
    @Published var percentString = "–"
    private var last: (date: Date, cpuSeconds: Double)?

    func sample() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return
        }
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let now = Date()
        guard let previous = last else {
            last = (now, cpuSeconds)
            return
        }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0.5 else {
            return
        }
        percentString = String(format: "%.1f%%", max((cpuSeconds - previous.cpuSeconds) / elapsed * 100, 0))
        last = (now, cpuSeconds)
    }
}

/// The investigation panel (design §2.6): replaces the dropdown. Reads
/// top-down — verdict, tiles (the abnormal one carries the only color),
/// processes, footprint. Answers "why" in at most two interactions.
struct PanelView: View, SizeChangeView {
    @EnvironmentObject var uiStore: UIStore
    @EnvironmentObject var healthStore: HealthStore
    @EnvironmentObject var cpuStore: CpuStore
    @EnvironmentObject var memoryStore: MemoryStore
    @EnvironmentObject var networkStore: NetworkStore
    @EnvironmentObject var gpuStore: GpuStore
    @EnvironmentObject var diskStore: DiskStore
    @EnvironmentObject var fanStore: FanStore
    @EnvironmentObject var batteryStore: BatteryStore
    @EnvironmentObject var bluetoothStore: BluetoothStore
    @EnvironmentObject var topStore: TopStore
    @EnvironmentObject var networkTopStore: NetworkTopStore
    @EnvironmentObject var preferenceStore: PreferenceStore
    @EnvironmentObject var fanControl: FanControlStore

    @StateObject private var selfUsage = SelfUsageSampler()
    @State private var cpuExpanded = false
    @State private var fansExpanded = false

    var onSizeChange: ((CGSize) -> Void)?

    private var secondary: Color {
        Color.primary.opacity(0.55)
    }

    private var cpuIsExpanded: Bool {
        cpuExpanded || healthStore.abnormalComponent == .CPU
    }

    // MARK: header

    private var verdictColor: Color {
        switch healthStore.level {
        case .normal:
            return .primary
        case .elevated:
            return DesignTokens.Health.elevated
        case .critical:
            return DesignTokens.Health.critical
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let upTime = cpuStore.upTimeString {
            parts.append(String(format: "panel.up".localized(), upTime))
        }
        if healthStore.level == .normal {
            parts.append("panel.nothing_needs_you".localized())
        }
        return parts.joined(separator: " · ")
    }

    /// update discovery moved here from the deleted bar badge/menu header
    /// (1.x .showInStatusBar) — the panel is the new surface
    private var showUpdateRow: Bool {
        preferenceStore.upgradeMethod != .none && preferenceStore.isUpdateAvailable == true
    }

    private var header: some View {
        HStack(spacing: 10) {
            EyesGlyph(state: healthStore.glyphState, width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(healthStore.verdictText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(verdictColor)
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(secondary)
                if showUpdateRow, let url = preferenceStore.latestReleaseURL {
                    Button(action: {
                        NSWorkspace.shared.open(url)
                    }) {
                        Text("\("ui.new_version".localized()) — \("ui.download".localized())")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 1)
                }
                // an active override must be impossible to forget (§2.7) —
                // second header line with one-click revert
                if fanControl.overrideActive {
                    HStack(spacing: 6) {
                        Text("\("fan.control.override".localized()) · \(fanControl.overrideMinutes)m")
                        Button(action: {
                            fanControl.revertAllToAuto()
                        }) {
                            Text("fan.control.revert".localized())
                                .underline()
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .font(.system(size: 10.5))
                    .foregroundColor(secondary)
                    .padding(.top, 1)
                }
            }
            Spacer()
            Menu {
                Button("menu.preferences".localized()) {
                    AppDelegate.openPreferences()
                }
                Divider()
                Button("menu.quit".localized()) {
                    AppDelegate.quit()
                }
            } label: {
                Text("···")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(secondary)
            }
            .menuStyle(BorderlessButtonMenuStyle())
            .fixedSize()
        }
        .padding(EdgeInsets(top: 2, leading: 4, bottom: 12, trailing: 4))
    }

    // MARK: tiles

    private func tileDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .padding(.top, 6)
    }

    private func cpuTile() -> some View {
        let abnormal = healthStore.abnormalComponent == .CPU
        return PanelTile(
            label: "component.cpu".localized().uppercased(),
            aux: cpuStore.temp?.temperatureString,
            abnormal: abnormal
        ) {
            Text(cpuStore.usageString)
                .font(DesignTokens.Typo.hero)
            Sparkline(values: healthStore.cpuHistory, maxValue: 100, color: abnormal ? DesignTokens.Health.elevated : .primary)
                .frame(height: 22)
                .padding(.top, 2)
            Text(abnormal ? healthStore.verdictText : String(format: "panel.cores".localized(), cpuStore.logicalCores))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
            if cpuIsExpanded {
                tileDivider()
                CoreGrid(usages: cpuStore.coreUsages, labels: cpuStore.coreLabels, abnormal: abnormal)
                    .padding(.top, 8)
                Text("\("panel.load".localized()) \(cpuStore.loadAverage1MinString) · \(cpuStore.loadAverage5MinString) · \(cpuStore.loadAverage15MinString)\(cpuStore.upTimeString.map { "  ·  \(String(format: "panel.up".localized(), $0))" } ?? "")")
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.top, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            cpuExpanded.toggle()
        }
    }

    private func memoryTile() -> AnyView {
        let total = memoryStore.total
        let sub = String(
            format: "%@ %.1f · %@ %.1f · %@ %.1f GB",
            "memory.app".localized(),
            memoryStore.appMemory,
            "memory.wired".localized(),
            memoryStore.wired,
            "memory.compressed".localized(),
            memoryStore.compressed
        )
        return AnyView(PanelTile(
            label: "component.memory".localized().uppercased(),
            aux: "\("memory.swap".localized()) \(memoryStore.swapUsed.memoryString)",
            abnormal: healthStore.abnormalComponent == .Memory
        ) {
            Text(memoryStore.usedPercentageString)
                .font(DesignTokens.Typo.hero)
            SegmentBar(segments: total > 0 ? [
                (memoryStore.appMemory / total, 0.95),
                (memoryStore.wired / total, 0.5),
                (memoryStore.compressed / total, 0.28),
            ] : [])
            Text(sub)
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
                .padding(.top, 2)
        })
    }

    private func networkTile() -> AnyView {
        // NetworkPort.description handles the optional port name ("Wi-Fi (en0)")
        let aux = networkStore.currentActivePort.map { $0.description }
        let historyMax = max(healthStore.networkHistory.max() ?? 1, 1)
        return AnyView(PanelTile(label: "component.network".localized().uppercased(), aux: aux) {
            HStack(spacing: 2) {
                Text("↓").foregroundColor(secondary).font(.system(size: 11))
                Text(networkStore.inSpeed).font(DesignTokens.Typo.mid)
            }
            HStack(spacing: 2) {
                Text("↑").foregroundColor(secondary).font(.system(size: 11))
                Text(networkStore.outSpeed).font(DesignTokens.Typo.mid)
            }
            Sparkline(values: healthStore.networkHistory, maxValue: historyMax)
                .frame(height: 22)
                .padding(.top, 2)
        })
    }

    private func gpuTile() -> AnyView {
        let gpu = gpuStore.gpus.first
        var sub = gpu?.model ?? "component.gpu".localized()
        if let cores = gpu?.cores {
            sub += " · " + String(format: "panel.cores".localized(), cores)
        }
        return AnyView(PanelTile(
            label: "component.gpu".localized().uppercased(),
            aux: gpuStore.temperatureAverage?.temperatureString
        ) {
            Text(gpuStore.usageAverageString ?? "N/A")
                .font(DesignTokens.Typo.hero)
            Spacer(minLength: 0)
            Text(sub)
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
        })
    }

    private func diskTile() -> AnyView {
        let usedFraction: Double
        if let ceiling = diskStore.ceilingBytes, let free = diskStore.freeBytes, ceiling > 0 {
            usedFraction = Double(ceiling - free) / Double(ceiling)
        } else {
            usedFraction = 0
        }
        return AnyView(PanelTile(
            label: "component.disk".localized().uppercased(),
            aux: diskStore.usagePercentageString,
            abnormal: healthStore.abnormalComponent == .Disk
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(diskStore.freeString)
                    .font(Font.system(size: 19, weight: .semibold).monospacedDigit())
                Text("text_component.free".localized().lowercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondary)
            }
            SegmentBar(segments: [(usedFraction, 0.95)])
            Text(String(format: "panel.of".localized(), diskStore.totalString))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
        })
    }

    private var fanModeText: String {
        let modes = Set(fanControl.overrides.values.map { $0.mode })
        if modes.isEmpty {
            return "fan.mode.auto".localized()
        }
        if modes == [.boost] {
            return "fan.mode.boost".localized()
        }
        return "fan.mode.manual".localized()
    }

    /// Readings always; the control surface lives in the expanded state —
    /// intervention happens next to the temperatures that justify it (§2.7).
    /// On macOS < 13 there is nothing to expand: plain readings, no tap
    /// affordance, no teaser (absent, never gray).
    private func fansTile() -> AnyView {
        let controllable = fanControl.status != .unsupportedOS
        let expanded = fansExpanded && controllable
        let tile = PanelTile(label: "component.fan".localized().uppercased(), aux: fanModeText) {
            if !expanded {
                ForEach(fanStore.fans) { fan in
                    HStack(spacing: 4) {
                        Text("\(fan.id + 1)")
                            .font(.system(size: 11))
                            .foregroundColor(secondary)
                        Text(fan.currentSpeedString)
                            .font(DesignTokens.Typo.mid)
                    }
                }
                Spacer(minLength: 0)
                Text(fanControl.status == .enabled && fanControl.overrideActive
                    ? "fan.control.override".localized()
                    : "panel.fans.system_managed".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
            } else {
                if fanControl.status != .enabled {
                    ForEach(fanStore.fans) { fan in
                        HStack(spacing: 4) {
                            Text("\(fan.id + 1)")
                                .font(.system(size: 11))
                                .foregroundColor(secondary)
                            Text(fan.currentSpeedString)
                                .font(DesignTokens.Typo.mid)
                        }
                    }
                }
                tileDivider()
                FanControlSurface()
                    .padding(.top, 2)
            }
        }
        guard controllable else {
            return AnyView(tile)
        }
        return AnyView(
            tile
                .contentShape(Rectangle())
                .onTapGesture {
                    fansExpanded.toggle()
                }
        )
    }

    private func batteryTile() -> AnyView {
        AnyView(PanelTile(
            label: "component.battery".localized().uppercased(),
            aux: batteryStore.timeRemaining
        ) {
            Text(batteryStore.charge.percentageString)
                .font(DesignTokens.Typo.hero)
            Spacer(minLength: 0)
            Text(String(format: "panel.battery.sub".localized(), batteryStore.health.percentageString, "\(batteryStore.cycleCount)"))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
        })
    }

    private func bluetoothDeviceDescription(_ device: BluetoothDevice) -> String {
        if device.batteryPercentLeft != nil || device.batteryPercentRight != nil || device.batteryPercentCase != nil {
            var parts: [String] = []
            if let left = device.batteryPercentLeft {
                parts.append("L \(left)")
            }
            if let right = device.batteryPercentRight {
                parts.append("R \(right)")
            }
            if let casePercent = device.batteryPercentCase {
                parts.append("C \(casePercent)")
            }
            return parts.joined(separator: " · ")
        }
        return device.batteryPercent.map { "\($0)%" } ?? ""
    }

    private func bluetoothTile(devices: [BluetoothDevice]) -> AnyView {
        AnyView(PanelTile(
            label: "component.bluetooth".localized().uppercased(),
            aux: "\(devices.count)"
        ) {
            ForEach(devices.prefix(2), id: \.address) { device in
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(bluetoothDeviceDescription(device))
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                }
            }
            Spacer(minLength: 0)
        })
    }

    private func pairRows(_ views: [AnyView]) -> some View {
        VStack(spacing: DesignTokens.Panel.spacing) {
            ForEach(0..<(views.count + 1) / 2, id: \.self) { row in
                HStack(alignment: .top, spacing: DesignTokens.Panel.spacing) {
                    views[row * 2]
                    if row * 2 + 1 < views.count {
                        views[row * 2 + 1]
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var tileGrid: some View {
        // expanded tiles promote to full width (design: grid-column 1/-1)
        var fullWidth: [AnyView] = []
        var rest: [AnyView] = []

        if cpuIsExpanded {
            fullWidth.append(AnyView(cpuTile()))
        } else {
            rest.append(AnyView(cpuTile()))
        }
        rest.append(contentsOf: [memoryTile(), networkTile(), gpuTile(), diskTile()])
        if fanStore.fans.count > 0 {
            if fansExpanded, fanControl.status != .unsupportedOS {
                fullWidth.append(fansTile())
            } else {
                rest.append(fansTile())
            }
        }
        if batteryStore.isValid {
            rest.append(batteryTile())
        }
        let btDevices = bluetoothStore.devices.filter { $0.hasBattery }
        if btDevices.count > 0 {
            rest.append(bluetoothTile(devices: btDevices))
        }

        return VStack(spacing: DesignTokens.Panel.spacing) {
            ForEach(0..<fullWidth.count, id: \.self) { index in
                fullWidth[index]
            }
            pairRows(rest)
        }
    }

    // MARK: processes

    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(UIStore.ProcLens.allCases) { lens in
                Text(lens.localizedDescription)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(uiStore.panelLens == lens ? Color.primary.opacity(0.15) : Color.clear)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        uiStore.panelLens = lens
                    }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(7)
    }

    private var processRows: [AnyView] {
        switch uiStore.panelLens {
        case .cpu:
            return topStore.cpuTopProcesses.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: String(format: "%.1f%%", $0.value)))
            }
        case .memory:
            return topStore.ramTopProcesses.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: ByteUnit(megaBytes: $0.usageAmount).readable))
            }
        case .network:
            return networkTopStore.processes.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: "↓ " + ByteUnit($0.value.inSpeedInByte).readable + "/s"))
            }
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("panel.top_processes".localized().uppercased())
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(secondary)
                Spacer()
                lensPicker
            }
            let rows = processRows
            if rows.isEmpty {
                Text("panel.collecting".localized())
                    .font(DesignTokens.Typo.sub)
                    .foregroundColor(secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(0..<rows.count, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.09))
                                .frame(height: 1)
                        }
                        rows[index]
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 5, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.top, 10)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
                .padding(.top, 10)
            HStack {
                Text(String(format: "panel.updated_every".localized(), "\(preferenceStore.smcRefreshRate) s"))
                Spacer()
                Text(String(format: "panel.self_usage".localized(), selfUsage.percentString))
            }
            .font(DesignTokens.Typo.sub)
            .foregroundColor(secondary)
            .padding(EdgeInsets(top: 8, leading: 4, bottom: 0, trailing: 4))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tileGrid
            processSection
            footer
        }
        .padding(DesignTokens.Panel.padding)
        .frame(width: DesignTokens.Panel.width)
        .fixedSize()
        .overlay(FanCeremonyOverlay())
        .background(GeometryReader { self.reportSize($0) })
        .onPreferenceChange(SizePreferenceKey.self, perform: { value in
            if let size = value.first {
                onSizeChange?(size)
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: .StoreShouldRefresh)) { _ in
            selfUsage.sample()
        }
        .onReceive(uiStore.$menuOpened) { opened in
            if opened {
                bluetoothStore.fetchAsync()
            }
        }
        .id(preferenceStore.language)
        .preferredColorScheme()
    }
}
