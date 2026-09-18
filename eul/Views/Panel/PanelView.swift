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
    @State private var networkExpanded = false
    /// the address most recently copied, so its row can confirm the copy;
    /// cleared on a delay (see copyAddress)
    @State private var copiedAddressID: String?

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
        guard let upTime = cpuStore.upTimeString else {
            return ""
        }
        return String(format: "panel.up".localized(), upTime)
    }

    /// update discovery moved here from the deleted bar badge/menu header
    /// (1.x .showInStatusBar) — the panel is the new surface
    private var showUpdateRow: Bool {
        preferenceStore.upgradeMethod != .none && preferenceStore.isUpdateAvailable == true
    }

    /// compact icon action (Clean / Preferences / Quit) — square so three fit
    /// where one text pill used to, leaving the title column room to breathe.
    /// The symbol carries a tooltip + a11y label since the word is gone.
    private func headerIcon(_ symbol: String, label: String, tint: Color, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(PlainButtonStyle())
        .background(background)
        .cornerRadius(6)
        .pointingHandCursor()
        .help(label)
        .accessibilityLabel(Text(label))
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            EyesGlyph(state: healthStore.glyphState, width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(healthStore.verdictText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(verdictColor)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // both actions one click away, no submenu; quit is immediate —
            // the helper's revert machinery makes quitting always safe
            HStack(spacing: 6) {
                headerIcon("gearshape", label: "menu.preferences".localized(), tint: secondary, background: Color.primary.opacity(0.08)) {
                    AppDelegate.openPreferences()
                }
                headerIcon("power", label: "menu.quit".localized(), tint: DesignTokens.Health.critical, background: DesignTokens.Health.critical.opacity(0.12)) {
                    AppDelegate.quit()
                }
            }
            .fixedSize()
        }
    }

    /// update discovery and the fan-override notice are panel-wide rows below
    /// the title — at this width they would wrap if squeezed beside the buttons
    private func updateRow(_ url: URL) -> some View {
        Button(action: {
            NSWorkspace.shared.open(url)
        }) {
            Text("\("ui.new_version".localized()) — \("ui.download".localized())")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .pointingHandCursor()
    }

    /// an active override must be impossible to forget (§2.7) — its own row
    /// with one-click revert
    private var overrideRow: some View {
        HStack(spacing: 6) {
            Text("\("fan.control.override".localized()) · \(fanControl.overrideMinutes)m")
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: {
                fanControl.revertAllToAuto()
            }) {
                Text("fan.control.revert".localized())
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(PlainButtonStyle())
            .pointingHandCursor()
            .fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundColor(secondary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            titleRow
            if showUpdateRow, let url = preferenceStore.latestReleaseURL {
                updateRow(url)
            }
            if fanControl.overrideActive {
                overrideRow
            }
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

    /// a tile's color cue comes from the health engine — sustained, debounced
    /// signals, never a raw sample (§2.4) — at the engine's current level
    private func tileSeverity(_ component: EulComponent) -> HealthLevel {
        healthStore.abnormalComponent == component ? healthStore.level : .normal
    }

    private func cpuTile() -> some View {
        let severity = tileSeverity(.CPU)
        return PanelTile(
            label: "component.cpu".localized().uppercased(),
            glyph: .CPU,
            aux: cpuStore.temp?.temperatureString,
            severity: severity
        ) {
            RollingNumber(cpuStore.usage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            PanelBars(values: healthStore.cpuHistory, color: severity.accent ?? .primary)
                .frame(height: 22)
                .padding(.top, 2)
            Text(severity != .normal ? healthStore.verdictText : String(format: "panel.cores".localized(), cpuStore.logicalCores))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
            // the per-core grid is the tile's most-asked question ("which
            // cores?"), so it no longer hides behind the expand — the tap now
            // only reveals the load averages
            tileDivider()
            CoreGrid(usages: cpuStore.coreUsages, labels: cpuStore.coreLabels, accent: severity.accent)
                .padding(.top, 8)
            if cpuIsExpanded {
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
        .pointingHandCursor()
        .a11yExpandButton(label: "component.cpu".localized())
    }

    private func memoryTile() -> some View {
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
        let severity = tileSeverity(.Memory)
        return PanelTile(
            label: "component.memory".localized().uppercased(),
            glyph: .Memory,
            aux: "\("memory.swap".localized()) \(memoryStore.swapUsed.memoryString)",
            severity: severity
        ) {
            RollingNumber(total > 0 ? memoryStore.usedPercentage : nil) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
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
            PanelBars(values: healthStore.memoryHistory, color: severity.accent ?? .primary)
                .frame(height: 16)
                .padding(.top, 3)
        }
    }

    /// bits ⇄ bytes is a stored choice made in Settings · General · Units
    /// (design §4.7) and applied everywhere a rate renders
    private func rateText(_ bytesPerSecond: Double) -> some View {
        let inBits = preferenceStore.networkRateInBits
        // value and unit are derived from the same rolling number, so they can
        // never disagree mid-roll (e.g. a transient "900 MB/s" while the value
        // is still crossing the KB→MB boundary)
        return RollingValue(bytesPerSecond) { value in
            let parts = ByteUnit(value).readableParts(inBits: inBits)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(parts.value).font(DesignTokens.Typo.mid)
                Text("\(parts.unit)/s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondary)
            }
        }
    }

    /// Copy one address and let its row say so. The panel is narrow enough
    /// that long IPv6 addresses render truncated, so the click is the only
    /// reliable way to get the full value out — the confirmation matters.
    private func copyAddress(_ address: Info.InterfaceAddress) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address.address, forType: .string)
        copiedAddressID = address.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            // a newer copy owns the confirmation now — leave it alone
            if copiedAddressID == address.id {
                copiedAddressID = nil
            }
        }
    }

    /// One tappable address. A Button (not a tap gesture) so the click is
    /// consumed here instead of also reaching the tile's expand/collapse
    /// gesture underneath.
    private func addressButton(_ address: Info.InterfaceAddress) -> some View {
        let copied = copiedAddressID == address.id
        return Button(action: { copyAddress(address) }) {
            Text(copied ? "panel.network.copied".localized() : address.address)
                .font(Font.system(size: 11).monospacedDigit())
                .foregroundColor(copied ? .primary : .primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(copied ? 0.15 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .pointingHandCursor()
        .help("panel.network.copy_hint".localized())
        .accessibilityLabel("\(address.device) \(address.address)")
        .accessibilityHint("panel.network.copy_hint".localized())
    }

    /// One adapter's addresses: the interface on the left, its bound
    /// addresses stacked on the right so several on one adapter read as one
    /// group rather than repeating the device name per row.
    private func addressRow(_ adapter: NetworkStore.Adapter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(adapter.title)
                .font(.system(size: 11))
                .foregroundColor(secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                ForEach(adapter.addresses) { address in
                    addressButton(address)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func networkTile() -> AnyView {
        // NetworkPort.description handles the optional port name ("Wi-Fi (en0)")
        let aux = networkStore.currentActivePort.map { $0.description }
        let adapters = networkStore.adapters
        let tile = PanelTile(label: "component.network".localized().uppercased(), glyph: .Network, aux: aux) {
            HStack(spacing: 2) {
                Text("↓").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.inSpeedInByte)
            }
            HStack(spacing: 2) {
                Text("↑").foregroundColor(secondary).font(.system(size: 11))
                rateText(networkStore.outSpeedInByte)
            }
            PanelBars(values: healthStore.networkHistory)
                .frame(height: 22)
                .padding(.top, 2)
            if networkExpanded, !adapters.isEmpty {
                tileDivider()
                Text("panel.network.addresses".localized().uppercased())
                    .font(DesignTokens.Typo.tileLabel)
                    .tracking(0.6)
                    .foregroundColor(secondary)
                    .padding(.top, 6)
                ForEach(adapters) { adapter in
                    addressRow(adapter)
                }
            }
        }
        // nothing to expand into until the first refresh has landed
        guard !adapters.isEmpty else {
            return AnyView(tile)
        }
        return AnyView(
            tile
                .contentShape(Rectangle())
                .onTapGesture {
                    networkExpanded.toggle()
                }
                .pointingHandCursor()
                .a11yExpandButton(label: "component.network".localized())
        )
    }

    private func gpuTile() -> some View {
        let gpu = gpuStore.gpus.first
        var sub = gpu?.model ?? "component.gpu".localized()
        if let cores = gpu?.cores {
            sub += " · " + String(format: "panel.cores".localized(), cores)
        }
        return PanelTile(
            label: "component.gpu".localized().uppercased(),
            glyph: .GPU,
            aux: gpuStore.temperatureAverage?.temperatureString
        ) {
            RollingNumber(gpuStore.usageAverage) { String(format: "%.0f%%", $0) }
                .font(DesignTokens.Typo.hero)
            PanelBars(values: healthStore.gpuHistory)
                .frame(height: 16)
                .padding(.top, 3)
            Spacer(minLength: 0)
            Text(sub)
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .lineLimit(1)
        }
    }

    private func diskTile() -> some View {
        let usedFraction: Double
        if let ceiling = diskStore.ceilingBytes, let free = diskStore.freeBytes, ceiling > 0 {
            usedFraction = Double(ceiling - free) / Double(ceiling)
        } else {
            usedFraction = 0
        }
        let severity = tileSeverity(.Disk)
        return PanelTile(
            label: "component.disk".localized().uppercased(),
            glyph: .Disk,
            aux: diskStore.usagePercentageString,
            severity: severity
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                RollingNumber(diskStore.freeBytes.map { Double($0) }) { ByteUnit($0, kilo: 1000).readable }
                    .font(Font.system(size: 19, weight: .semibold).monospacedDigit())
                    .foregroundColor(severity.accent ?? .primary)
                Text("text_component.free".localized().lowercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(secondary)
            }
            SegmentBar(segments: [(usedFraction, 0.95)])
            Text(String(format: "panel.of".localized(), diskStore.totalString))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
                .padding(.top, 2)
        }
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
        // an unreachable helper means the controls would silently no-op —
        // the tile carries the cue so the repair affordance gets found
        let severity: HealthLevel = fanControl.status == .enabled && fanControl.helperUnreachable ? .elevated : .normal
        let tile = PanelTile(label: "component.fan".localized().uppercased(), glyph: .Fan, aux: fanModeText, severity: severity) {
            if !expanded {
                ForEach(fanStore.fans) { fan in
                    HStack(spacing: 4) {
                        Text("\(fan.id + 1)")
                            .font(.system(size: 11))
                            .foregroundColor(secondary)
                        RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
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
                            RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
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
                .pointingHandCursor()
                .a11yExpandButton(label: "component.fan".localized())
        )
    }

    /// the one display-only cue: charge is monotonic on battery power, so a
    /// plain threshold can't flap like a raw usage sample would. Plugged in,
    /// a low percentage is a non-event — no color.
    private var batterySeverity: HealthLevel {
        guard !batteryStore.acPowered else {
            return .normal
        }
        if batteryStore.charge <= 0.1 {
            return .critical
        }
        if batteryStore.charge <= 0.2 {
            return .elevated
        }
        return .normal
    }

    private func batteryTile() -> some View {
        let severity = batterySeverity
        return PanelTile(
            label: "component.battery".localized().uppercased(),
            glyph: .Battery,
            aux: batteryStore.timeRemaining,
            severity: severity
        ) {
            RollingNumber(batteryStore.charge) { $0.percentageString }
                .font(DesignTokens.Typo.hero)
                .foregroundColor(severity.accent ?? .primary)
            Spacer(minLength: 0)
            Text(String(format: "panel.battery.sub".localized(), batteryStore.health.percentageString, "\(batteryStore.cycleCount)"))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
        }
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

    private func bluetoothTile(devices: [BluetoothDevice]) -> some View {
        PanelTile(
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
        }
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

    /// right-click → hide; hiding is point-of-use, restore lives in
    /// Settings · General (design §4.7)
    private func hideable(_ kind: PanelTileKind, _ view: some View) -> AnyView {
        AnyView(view.contextMenu {
            Button(String(format: "panel.tile.hide".localized(), kind.localizedDescription)) {
                preferenceStore.hideTile(kind)
            }
        })
    }

    private var tileGrid: some View {
        // expanded tiles promote to full width (design: grid-column 1/-1)
        var fullWidth: [AnyView] = []
        var rest: [AnyView] = []
        let hidden = preferenceStore.isTileHidden

        if !hidden(.cpu) {
            if cpuIsExpanded {
                fullWidth.append(hideable(.cpu, cpuTile()))
            } else {
                rest.append(hideable(.cpu, cpuTile()))
            }
        }
        if !hidden(.memory) {
            rest.append(hideable(.memory, memoryTile()))
        }
        if !hidden(.network) {
            if networkExpanded {
                fullWidth.append(hideable(.network, networkTile()))
            } else {
                rest.append(hideable(.network, networkTile()))
            }
        }
        if !hidden(.gpu) {
            rest.append(hideable(.gpu, gpuTile()))
        }
        if !hidden(.disk) {
            rest.append(hideable(.disk, diskTile()))
        }
        if fanStore.fans.count > 0, !hidden(.fans) {
            if fansExpanded, fanControl.status != .unsupportedOS {
                fullWidth.append(hideable(.fans, fansTile()))
            } else {
                rest.append(hideable(.fans, fansTile()))
            }
        }
        if batteryStore.isValid, !hidden(.battery) {
            rest.append(hideable(.battery, batteryTile()))
        }
        let btDevices = bluetoothStore.devices.filter { $0.hasBattery }
        if btDevices.count > 0, !hidden(.bluetooth) {
            rest.append(hideable(.bluetooth, bluetoothTile(devices: btDevices)))
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
                Button(action: {
                    uiStore.panelLens = lens
                }) {
                    Text(lens.localizedDescription)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(uiStore.panelLens == lens ? Color.primary.opacity(0.15) : Color.clear)
                        .cornerRadius(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .pointingHandCursor()
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
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: String(format: "%.1f%%", $0.value), pid: $0.pid))
            }
        case .memory:
            return topStore.ramTopProcesses.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: ByteUnit(megaBytes: $0.usageAmount).readable, pid: $0.pid))
            }
        case .network:
            return networkTopStore.processes.prefix(6).map {
                AnyView(PanelProcessRow(icon: $0.runningApp?.icon, name: $0.displayName, value: "↓ " + ByteUnit($0.value.inSpeedInByte).readableRate(inBits: preferenceStore.networkRateInBits), pid: $0.pid))
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
