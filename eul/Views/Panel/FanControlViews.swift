//
//  FanControlViews.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// VoiceOver name + value for the fan sliders; gated since the accessibility
/// modifiers are macOS 11+ and the app floor is 10.15 (the control surface
/// itself only renders on macOS 13+ at runtime)
private extension View {
    @ViewBuilder
    func fanSliderAccessibility(label: String, value: String) -> some View {
        if #available(macOS 11.0, *) {
            accessibilityLabel(Text(label)).accessibilityValue(Text(value))
        } else {
            self
        }
    }
}

/// Expanded FANS tile content (design §2.7/§4.6): readings always; on
/// macOS 13+ either the single quiet "Control fans…" affordance (locked) or
/// the per-fan Auto/Manual/Boost surface with the permanent safety strip.
/// On macOS < 13 control is absent — readings only, no teaser.
struct FanControlSurface: View {
    @EnvironmentObject var fanControl: FanControlStore
    @EnvironmentObject var fanStore: FanStore

    /// slider positions while dragging; committed to the helper on release
    @State private var pendingTargets: [Int: Double] = [:]
    @State private var pendingLinkedPercent: Double?

    private var secondary: Color {
        Color.primary.opacity(0.55)
    }

    private func modeLabel(_ mode: FanControlStore.Mode) -> String {
        "fan.mode.\(mode.rawValue)".localized()
    }

    private func currentMode(_ fanID: Int) -> FanControlStore.Mode {
        fanControl.overrides[fanID]?.mode ?? .auto
    }

    private func availableModes(for fan: FanData) -> [FanControlStore.Mode] {
        // boost needs a readable hardware max — without it the helper would
        // clamp the target to MINIMUM, the opposite of boost
        fan.maxSpeed != nil && fan.maxSpeed! > 0
            ? [.auto, .manual, .boost]
            : [.auto, .manual]
    }

    private func modePicker(modes: [FanControlStore.Mode], current: FanControlStore.Mode, onSelect: @escaping (FanControlStore.Mode) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.rawValue) { mode in
                Button(action: {
                    onSelect(mode)
                }) {
                    Text(modeLabel(mode))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(current == mode ? Color.primary.opacity(0.15) : Color.clear)
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

    private func modePicker(for fan: FanData) -> some View {
        modePicker(modes: availableModes(for: fan), current: currentMode(fan.id)) { mode in
            pendingTargets.removeValue(forKey: fan.id)
            fanControl.setMode(fanID: fan.id, mode: mode, fanData: fan)
        }
    }

    // MARK: linked control (one slider drives every fan)

    /// slider detents: 0% = each fan's hardware minimum, 100% = its maximum
    private static let linkedStep: Double = 20

    private var linkableFans: [FanData] {
        fanStore.fans.filter { fan in
            guard let minSpeed = fan.minSpeed, let maxSpeed = fan.maxSpeed else {
                return false
            }
            return maxSpeed > minSpeed
        }
    }

    private var showLinked: Bool {
        fanControl.linked && fanStore.fans.count > 1 && !linkableFans.isEmpty
    }

    private var linkedMode: FanControlStore.Mode {
        let modes = Set(fanStore.fans.compactMap { fanControl.overrides[$0.id]?.mode })
        if modes.isEmpty {
            return .auto
        }
        if modes == [.boost] {
            return .boost
        }
        return .manual
    }

    private var linkedAvailableModes: [FanControlStore.Mode] {
        fanStore.fans.allSatisfy { ($0.maxSpeed ?? 0) > 0 }
            ? [.auto, .manual, .boost]
            : [.auto, .manual]
    }

    /// where this fan sits in its own controllable range, 0...100
    private func percent(of fan: FanData) -> Double? {
        guard let minSpeed = fan.minSpeed, let maxSpeed = fan.maxSpeed, maxSpeed > minSpeed else {
            return nil
        }
        let value = fanControl.overrides[fan.id]?.target ?? Double(fan.currentSpeed ?? minSpeed)
        return min(max((value - Double(minSpeed)) / Double(maxSpeed - minSpeed) * 100, 0), 100)
    }

    private var linkedCurrentPercent: Double {
        let values = linkableFans.compactMap { percent(of: $0) }
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func snapped(_ value: Double) -> Double {
        (value / Self.linkedStep).rounded() * Self.linkedStep
    }

    private func setLinkedPercent(_ value: Double) {
        for fan in linkableFans {
            guard let minSpeed = fan.minSpeed, let maxSpeed = fan.maxSpeed else {
                continue
            }
            fanControl.setTarget(fanID: fan.id, target: Double(minSpeed) + value / 100 * Double(maxSpeed - minSpeed))
        }
    }

    private func setLinkedMode(_ mode: FanControlStore.Mode) {
        pendingLinkedPercent = nil
        pendingTargets = [:]
        switch mode {
        case .manual:
            // pin every fan at the same point of its own range — the current
            // average, snapped to the slider's detents
            setLinkedPercent(snapped(linkedCurrentPercent))
        default:
            for fan in fanStore.fans {
                fanControl.setMode(fanID: fan.id, mode: mode, fanData: fan)
            }
        }
    }

    private var linkedSliderBinding: Binding<Double> {
        Binding(
            get: { pendingLinkedPercent ?? snapped(linkedCurrentPercent) },
            set: { pendingLinkedPercent = $0 }
        )
    }

    private var linkedControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // readouts stay per-fan — linking is control, not display
                ForEach(fanStore.fans) { fan in
                    HStack(spacing: 4) {
                        Text("\(fan.id + 1)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(secondary)
                        RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
                            .font(DesignTokens.Typo.sub)
                            .foregroundColor(secondary)
                    }
                }
                Spacer()
                modePicker(modes: linkedAvailableModes, current: linkedMode) { mode in
                    setLinkedMode(mode)
                }
            }
            if linkedMode == .manual {
                HStack(spacing: 8) {
                    Text("0%")
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                    Slider(value: linkedSliderBinding, in: 0...100, step: Self.linkedStep, onEditingChanged: { editing in
                        if !editing, let value = pendingLinkedPercent {
                            setLinkedPercent(value)
                            pendingLinkedPercent = nil
                        }
                    })
                    .fanSliderAccessibility(
                        label: "component.fan".localized(),
                        value: "\(Int(pendingLinkedPercent ?? snapped(linkedCurrentPercent)))%"
                    )
                    Text("100%")
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                }
                Text(String(
                    format: "fan.control.target".localized(),
                    "\(Int(pendingLinkedPercent ?? snapped(linkedCurrentPercent)))%",
                    fanStore.fans.map { "\($0.currentSpeed ?? 0)" }.joined(separator: " · ")
                ))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
            }
        }
        .padding(.top, 6)
    }

    private func sliderBinding(for fan: FanData, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: {
                pendingTargets[fan.id]
                    ?? fanControl.overrides[fan.id]?.target
                    ?? Double(fan.currentSpeed ?? Int(range.lowerBound))
            },
            set: { pendingTargets[fan.id] = min(max($0, range.lowerBound), range.upperBound) }
        )
    }

    private func manualControls(for fan: FanData) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let minSpeed = fan.minSpeed, let maxSpeed = fan.maxSpeed, maxSpeed > minSpeed {
                let range = Double(minSpeed)...Double(maxSpeed)
                HStack(spacing: 8) {
                    Text("\(minSpeed)")
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                    Slider(value: sliderBinding(for: fan, range: range), in: range, onEditingChanged: { editing in
                        if !editing, let target = pendingTargets[fan.id] {
                            fanControl.setTarget(fanID: fan.id, target: target)
                            pendingTargets.removeValue(forKey: fan.id)
                        }
                    })
                    .fanSliderAccessibility(
                        label: "\("component.fan".localized()) \(fan.id + 1)",
                        value: "\(Int(pendingTargets[fan.id] ?? fanControl.overrides[fan.id]?.target ?? Double(fan.currentSpeed ?? minSpeed))) rpm"
                    )
                    Text("\(maxSpeed)")
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                }
                // target vs actual — divergence is the safety model made
                // visible: macOS is cooling past the user's setting
                Text(String(
                    format: "fan.control.target".localized(),
                    "\(Int(pendingTargets[fan.id] ?? fanControl.overrides[fan.id]?.target ?? 0))",
                    "\(fan.currentSpeed ?? 0)"
                ))
                .font(DesignTokens.Typo.sub)
                .foregroundColor(secondary)
            }
        }
    }

    private var safetyStrip: some View {
        // permanently attached to the controls — never a dialog, never
        // dismissible (§4.6)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(["fan.control.safety.clamped", "fan.control.safety.system", "fan.control.safety.revert"], id: \.self) { key in
                Text(key.localized())
                    .font(.system(size: 9.5))
                    .foregroundColor(secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            }
        }
        .padding(.top, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch fanControl.status {
            case .unsupportedOS:
                EmptyView()
            case .notInstalled, .requiresApproval:
                // discovery without nagging: one quiet affordance, exactly
                // where the temperatures that motivate it live (P6)
                HStack {
                    Text("fan.control.managed_by_macos".localized())
                        .font(DesignTokens.Typo.sub)
                        .foregroundColor(secondary)
                    Spacer()
                    Button(action: {
                        fanControl.beginCeremony()
                    }) {
                        Text("fan.control.cta".localized())
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(7)
                    .pointingHandCursor()
                }
            case .enabled:
                if fanControl.helperUnreachable {
                    // registered but the daemon never answers (typically a
                    // stale launch constraint after a re-signed update) —
                    // controls would silently no-op, so say so and offer the
                    // one-click re-registration
                    HStack(alignment: .top, spacing: 8) {
                        Text("fan.control.unreachable".localized())
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DesignTokens.Health.elevated)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(action: {
                            fanControl.repairHelper()
                        }) {
                            Text("fan.control.repair".localized())
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(7)
                        .pointingHandCursor()
                    }
                }
                if showLinked {
                    linkedControls
                } else {
                    ForEach(fanStore.fans) { fan in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("\(fan.id + 1)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(secondary)
                                RollingNumber(fan.currentSpeed.map(Double.init)) { "\(Int($0)) rpm" }
                                    .font(DesignTokens.Typo.sub)
                                    .foregroundColor(secondary)
                                Spacer()
                                modePicker(for: fan)
                            }
                            if currentMode(fan.id) == .manual {
                                manualControls(for: fan)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                safetyStrip
                HStack(spacing: 12) {
                    Button(action: {
                        fanControl.removeHelper()
                    }) {
                        Text("fan.control.remove".localized())
                            .font(.system(size: 10.5))
                            .underline()
                            .foregroundColor(secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .pointingHandCursor()
                    if fanStore.fans.count > 1, !linkableFans.isEmpty {
                        Button(action: {
                            pendingLinkedPercent = nil
                            pendingTargets = [:]
                            fanControl.linked.toggle()
                        }) {
                            Text((fanControl.linked ? "fan.control.unlink" : "fan.control.link").localized())
                                .font(.system(size: 10.5))
                                .underline()
                                .foregroundColor(secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .pointingHandCursor()
                    }
                    Spacer()
                    if fanControl.overrideActive {
                        Button(action: {
                            fanControl.revertAllToAuto()
                        }) {
                            Text("fan.control.revert".localized())
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(7)
                        .pointingHandCursor()
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

/// The P6 ceremony sheet (design §4.6): explainer → macOS handoff → unlocked
/// in place. Denial is a non-event. Rendered as an overlay veil on the panel.
struct FanCeremonyOverlay: View {
    @EnvironmentObject var fanControl: FanControlStore

    private var secondary: Color {
        Color.primary.opacity(0.6)
    }

    private func bullet(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.system(size: 11, weight: .bold))
            Text(key.localized())
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(secondary)
    }

    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("fan.control.explainer.title".localized())
                .font(.system(size: 13, weight: .semibold))
            Text("fan.control.explainer.body".localized())
                .font(.system(size: 11.5))
                .foregroundColor(secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                bullet("fan.control.explainer.point1")
                bullet("fan.control.explainer.point2")
                bullet("fan.control.explainer.point3")
                bullet("fan.control.explainer.point4")
            }
            if !FanControlStore.buildIsSigned {
                // an unsigned build can never pass SMAppService validation —
                // say so up front, not after a doomed click
                Text("fan.control.unsigned".localized())
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DesignTokens.Health.elevated)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fanControl.installFailed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("fan.control.install_failed".localized())
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DesignTokens.Health.elevated)
                    if let detail = fanControl.installErrorText {
                        Text(detail)
                            .font(.system(size: 9.5))
                            .foregroundColor(secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(action: {
                    fanControl.cancelCeremony()
                }) {
                    Text("fan.control.not_now".localized())
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(7)
                .pointingHandCursor()
                Button(action: {
                    fanControl.installHelper()
                }) {
                    Text("fan.control.install".localized())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(NSColor.windowBackgroundColor))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary)
                .cornerRadius(7)
                .pointingHandCursor()
            }
            .padding(.top, 6)
        }
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("fan.control.waiting.title".localized())
                .font(.system(size: 13, weight: .semibold))
            Text("fan.control.waiting.body".localized())
                .font(.system(size: 11.5))
                .foregroundColor(secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: {
                    fanControl.cancelCeremony()
                }) {
                    Text("fan.control.not_now".localized())
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(7)
                .pointingHandCursor()
                Spacer()
                Button(action: {
                    fanControl.openApprovalSettings()
                }) {
                    Text("fan.control.open_settings".localized())
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.08))
                .cornerRadius(7)
                .pointingHandCursor()
            }
            .padding(.top, 6)
        }
    }

    var body: some View {
        if fanControl.ceremony != .idle {
            ZStack {
                Color.black.opacity(0.35)
                Group {
                    if fanControl.ceremony == .explainer {
                        explainerCard
                    } else {
                        waitingCard
                    }
                }
                .padding(16)
                .frame(width: 300)
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: Color.black.opacity(0.4), radius: 20, y: 10)
                )
            }
        }
    }
}
