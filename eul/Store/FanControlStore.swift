//
//  FanControlStore.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import Security
import ServiceManagement

/// App side of fan control (design §2.7/§4.6, asks 15–17). Owns the helper
/// lifecycle and the P6 ceremony: privilege is requested only at the moment
/// the user first enables control — never at launch, never as a badge.
/// Requires macOS 13 (SMAppService); on older systems the affordance simply
/// does not exist. Direct-download builds only — there is no fan hardware
/// access in the sandboxed build anyway.
class FanControlStore: ObservableObject {
    enum HelperStatus {
        /// macOS < 13 — control is absent, readings remain
        case unsupportedOS
        case notInstalled
        /// registered, pending the user's toggle in System Settings
        case requiresApproval
        case enabled
    }

    enum Ceremony {
        case idle
        case explainer
        case waiting
    }

    enum Mode: String {
        case auto
        case manual
        case boost
    }

    struct Override {
        var mode: Mode
        var target: Double
    }

    @Published var status: HelperStatus = .unsupportedOS
    @Published var ceremony: Ceremony = .idle
    @Published var overrides: [Int: Override] = [:]
    @Published var overrideSince: Date?
    @Published var installFailed = false
    /// the underlying SMAppService error, surfaced so a failed install is
    /// diagnosable instead of mute
    @Published var installErrorText: String?
    /// registration says enabled but the daemon never answers — the classic
    /// cause is a stale BTM launch constraint after the app was re-signed
    /// (launchd SIGKILLs the helper at spawn); surfaced with a Repair action
    @Published var helperUnreachable = false
    /// multi-fan Macs get ONE control by default — both fans move together
    /// as a percentage of each fan's own range; per-fan control is the
    /// opt-out, persisted so a deliberate unlink survives relaunch
    @Published var linked: Bool = UserDefaults.standard.object(forKey: "fanControlLinked") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(linked, forKey: "fanControlLinked")
        }
    }

    /// SMAppService validates signatures — an unsigned (ad-hoc) build can
    /// never register the daemon. Detected up front so the ceremony can say
    /// so instead of failing mutely after a click.
    static let buildIsSigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code = code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode = staticCode else {
            return false
        }
        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty
        else {
            return false
        }
        return true
    }()

    private var pingTimer: Timer?
    private var approvalPollTimer: Timer?
    private var connection: NSXPCConnection?
    private var panelCancellable: AnyCancellable?

    var overrideActive: Bool {
        !overrides.isEmpty
    }

    var overrideMinutes: Int {
        overrideSince.map { max(1, Int(Date().timeIntervalSince($0) / 60)) } ?? 0
    }

    init() {
        refreshStatus()
        // SMAppService.status has no change notification — re-read on every
        // panel open (the user may have toggled the daemon in System
        // Settings), and don't poll for approval while nobody is looking
        panelCancellable = SharedStore.ui.$menuOpened.sink { [weak self] opened in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                if opened {
                    self.refreshStatus()
                    self.checkHelperReachable()
                    if self.ceremony == .waiting {
                        self.startApprovalPolling()
                    }
                } else {
                    self.stopApprovalPolling()
                }
            }
        }
    }

    // MARK: helper lifecycle

    func refreshStatus() {
        guard #available(macOS 13.0, *) else {
            status = .unsupportedOS
            return
        }
        switch SMAppService.daemon(plistName: FanHelperConstants.plistName).status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        default:
            // .notFound before first registration is the normal initial state
            status = .notInstalled
        }
    }

    func beginCeremony() {
        installFailed = false
        installErrorText = nil
        ceremony = .explainer
    }

    /// Denial is a non-event (§4.6): close back to readings, never re-ask,
    /// never count attempts
    func cancelCeremony() {
        ceremony = .idle
        installFailed = false
        installErrorText = nil
        stopApprovalPolling()
    }

    func installHelper() {
        guard #available(macOS 13.0, *) else {
            return
        }
        let service = SMAppService.daemon(plistName: FanHelperConstants.plistName)
        var registerError: String?
        do {
            try service.register()
        } catch {
            // expected on first registration: the system flips the service
            // to .requiresApproval and the user approves in System Settings
            Print("helper register:", error.localizedDescription)
            registerError = error.localizedDescription
        }
        refreshStatus()
        switch status {
        case .enabled:
            ceremony = .idle
            checkHelperReachable()
        case .requiresApproval:
            ceremony = .waiting
            SMAppService.openSystemSettingsLoginItems()
            startApprovalPolling()
        default:
            // registration failed outright (e.g. unsigned dev build —
            // SMAppService validates signatures). Stay on the explainer and
            // say so plainly; "Not now" remains one click away.
            installFailed = true
            installErrorText = registerError
        }
    }

    func openApprovalSettings() {
        guard #available(macOS 13.0, *) else {
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }

    /// "Enabled" only proves the registration; the daemon must answer too.
    /// A ping that errors instead of replying means launchd can't keep the
    /// helper alive — seen in the field when the BTM record's launch
    /// constraint was snapshotted from a previous signing of the app and the
    /// kernel kills the new binary at spawn (EX_CONFIG). Checked on panel
    /// open, never at app launch (P6: nothing privileged runs unprompted).
    func checkHelperReachable() {
        guard status == .enabled else {
            helperUnreachable = false
            return
        }
        proxy(onError: { [weak self] _ in
            DispatchQueue.main.async {
                self?.helperUnreachable = true
            }
        })?.ping { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.helperUnreachable = false
            }
        }
    }

    /// Re-register so BTM re-snapshots the helper's CURRENT signature: revert
    /// local state, unregister, then run the normal install path (macOS may
    /// ask for approval again — the ceremony handles it).
    func repairHelper() {
        guard #available(macOS 13.0, *) else {
            return
        }
        overrides = [:]
        updateOverrideState()
        connection?.invalidate()
        connection = nil
        try? SMAppService.daemon(plistName: FanHelperConstants.plistName).unregister()
        helperUnreachable = false
        installHelper()
        if installFailed {
            // a failed re-register must not be silent — the daemon is now
            // unregistered, so show the explainer, which carries the
            // installFailed/installErrorText UI (set directly: beginCeremony
            // would wipe the diagnostics)
            ceremony = .explainer
        }
    }

    /// Removal is first-class (§4.6): one click uninstalls the daemon and
    /// reverts fans — easier than installing, by design. The revert gets a
    /// bounded wait BEFORE unregister tears the daemon down; local state
    /// clears unconditionally — once the daemon dies, its own fallbacks
    /// (invalidation revert, SIGTERM, watchdog) return the hardware to auto.
    func removeHelper() {
        let semaphore = DispatchSemaphore(value: 0)
        if let helper = proxy(onError: { _ in semaphore.signal() }) {
            helper.revertAllToAuto { _ in
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 0.5)
        }
        overrides = [:]
        updateOverrideState()
        guard #available(macOS 13.0, *) else {
            return
        }
        try? SMAppService.daemon(plistName: FanHelperConstants.plistName).unregister()
        connection?.invalidate()
        connection = nil
        refreshStatus()
    }

    private func startApprovalPolling() {
        approvalPollTimer?.invalidate()
        approvalPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.refreshStatus()
            if self.status == .enabled {
                // approval unlocks the controls in place — no second dialog
                self.ceremony = .idle
                self.stopApprovalPolling()
                self.checkHelperReachable()
            }
        }
    }

    private func stopApprovalPolling() {
        approvalPollTimer?.invalidate()
        approvalPollTimer = nil
    }

    // MARK: XPC

    private func proxy(onError: ((Error) -> Void)? = nil) -> FanHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(machServiceName: FanHelperConstants.machServiceName, options: .privileged)
            new.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                DispatchQueue.main.async {
                    self?.connection = nil
                }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            Print("fan helper XPC error:", error.localizedDescription)
            onError?(error)
        } as? FanHelperProtocol
    }

    // MARK: control

    func setMode(fanID: Int, mode: Mode, fanData: FanData) {
        switch mode {
        case .auto:
            proxy()?.setFanAuto(id: fanID) { error in
                DispatchQueue.main.async { [weak self] in
                    if error == nil {
                        self?.overrides.removeValue(forKey: fanID)
                        self?.updateOverrideState()
                    }
                }
            }
        case .manual:
            let target = overrides[fanID]?.target
                ?? Double(fanData.currentSpeed ?? fanData.minSpeed ?? 0)
            setTarget(fanID: fanID, target: target, mode: .manual)
        case .boost:
            // an unreadable max would clamp to MINIMUM in the helper —
            // the opposite of boost
            guard let maxSpeed = fanData.maxSpeed, maxSpeed > 0 else {
                return
            }
            setTarget(fanID: fanID, target: Double(maxSpeed), mode: .boost)
        }
    }

    /// optimistic: the UI keeps the dragged value; rolled back if the helper
    /// rejects or the XPC send fails
    func setTarget(fanID: Int, target: Double, mode: Mode = .manual) {
        let previous = overrides[fanID]
        overrides[fanID] = Override(mode: mode, target: target)
        updateOverrideState()

        let rollback: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else {
                    return
                }
                if let previous = previous {
                    self.overrides[fanID] = previous
                } else {
                    self.overrides.removeValue(forKey: fanID)
                }
                self.updateOverrideState()
            }
        }

        guard let helper = proxy(onError: { _ in rollback() }) else {
            rollback()
            return
        }
        helper.setFanForced(id: fanID, targetRPM: target) { error in
            if let error = error {
                Print("fan set failed:", error)
                rollback()
            }
        }
    }

    /// local state clears even if the send fails — the helper's own
    /// fallbacks (invalidation, watchdog) guarantee the hardware side
    func revertAllToAuto() {
        let clear: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                self?.overrides = [:]
                self?.updateOverrideState()
            }
        }
        guard let helper = proxy(onError: { _ in clear() }) else {
            clear()
            return
        }
        helper.revertAllToAuto { _ in
            clear()
        }
    }

    /// Best-effort synchronous revert for app termination; the helper's
    /// connection-invalidation handler and dead-man watchdog are the real
    /// guarantees
    func revertAllOnQuit() {
        guard overrideActive else {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        proxy()?.revertAllToAuto { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 0.5)
    }

    private func updateOverrideState() {
        if overrideActive {
            if overrideSince == nil {
                overrideSince = Date()
            }
            startPinging()
        } else {
            overrideSince = nil
            stopPinging()
        }
    }

    /// dead-man heartbeat while an override is active — if the app dies, the
    /// helper notices the silence and reverts on its own. The reply also
    /// reconciles published state with the helper's reality: a restarted
    /// helper reverts-and-forgets, so stale local overrides must drop.
    private func startPinging() {
        guard pingTimer == nil else {
            return
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.proxy()?.ping { _, overriddenIDs in
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }
                    let helperSet = Set(overriddenIDs)
                    let stale = self.overrides.keys.filter { !helperSet.contains($0) }
                    if !stale.isEmpty {
                        stale.forEach { self.overrides.removeValue(forKey: $0) }
                        self.updateOverrideState()
                    }
                }
            }
        }
    }

    private func stopPinging() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}
