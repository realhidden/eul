//
//  FanControlViews.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// Expanded FANS tile content (design §2.7/§4.6): readings always; on
/// macOS 13+ either the single quiet "Control fans…" affordance (locked) or
/// the per-fan Auto/Manual/Boost surface with the permanent safety strip.
/// On macOS < 13 control is absent — readings only, no teaser.
struct FanControlSurface: View {
    @EnvironmentObject var fanControl: FanControlStore
    @EnvironmentObject var fanStore: FanStore

    /// slider positions while dragging; committed to the helper on release
    @State private var pendingTargets: [Int: Double] = [:]

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

    private func modePicker(for fan: FanData) -> some View {
        HStack(spacing: 2) {
            ForEach(availableModes(for: fan), id: \.rawValue) { mode in
                Text(modeLabel(mode))
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(currentMode(fan.id) == mode ? Color.primary.opacity(0.15) : Color.clear)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        pendingTargets.removeValue(forKey: fan.id)
                        fanControl.setMode(fanID: fan.id, mode: mode, fanData: fan)
                    }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(7)
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
                    }
                }
                ForEach(fanStore.fans) { fan in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("\(fan.id + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(secondary)
                            Text(fan.currentSpeedString)
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
                safetyStrip
                HStack {
                    Button(action: {
                        fanControl.removeHelper()
                    }) {
                        Text("fan.control.remove".localized())
                            .font(.system(size: 10.5))
                            .underline()
                            .foregroundColor(secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
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
