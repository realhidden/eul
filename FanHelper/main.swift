//
//  main.swift
//  FanHelper
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//
//  Privileged fan helper daemon (design §4.6 / asks 15–16). Registered via
//  SMAppService from the app at the moment the user first enables fan
//  control — never at launch (P6). Launch-on-demand, root, no KeepAlive.
//
//  Safety invariants owned HERE, not by the UI:
//  - every target is clamped to the hardware's real F{id}Mn...F{id}Mx
//  - fans revert to Auto when: the last XPC connection drops, the dead-man
//    heartbeat goes silent, SIGTERM arrives, or the daemon starts (a crashed
//    predecessor may have left fans pinned)

import Foundation

final class FanController: NSObject, FanHelperProtocol {
    private let queue = DispatchQueue(label: "com.gaosun.eul.helper.fans")
    private var smcOpened = false
    private var overriddenFans = Set<Int>()
    private var lastPing = Date()

    var hasOverrides: Bool {
        queue.sync { !overriddenFans.isEmpty }
    }

    var secondsSinceLastPing: TimeInterval {
        queue.sync { Date().timeIntervalSince(lastPing) }
    }

    private func ensureSMC() throws {
        if !smcOpened {
            try SMCKit.open()
            smcOpened = true
        }
    }

    func setFanForced(id: Int, targetRPM: Double, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try ensureSMC()
                let count = (try? SMCKit.fanCount()) ?? 0
                guard id >= 0, id < count else {
                    reply("invalid fan id \(id)")
                    return
                }
                // validate + clamp in Double space — Int(Double) TRAPS on
                // NaN/infinity/out-of-range, and targetRPM crosses a trust
                // boundary; never trust the client
                guard targetRPM.isFinite else {
                    reply("invalid target RPM")
                    return
                }
                let minSpeed = (try? SMCKit.fanMinSpeed(id)) ?? 0
                let maxSpeed = (try? SMCKit.fanMaxSpeed(id)) ?? 0
                guard maxSpeed > 0 else {
                    reply("fan \(id) reports no max speed")
                    return
                }
                let clamped = Int(min(max(targetRPM, Double(max(minSpeed, 1))), Double(maxSpeed)))
                // track BEFORE writing: a partial write (mode set, target
                // failed) must stay covered by the revert machinery
                overriddenFans.insert(id)
                try SMCKit.fanSetForced(id, targetSpeed: clamped)
                lastPing = Date()
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func setFanAuto(id: Int, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                try ensureSMC()
                try SMCKit.fanSetAuto(id)
                overriddenFans.remove(id)
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func revertAllToAuto(reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            reply(revertAllLocked())
        }
    }

    /// must be called on `queue`
    private func revertAllLocked() -> String? {
        do {
            try ensureSMC()
            let count = (try? SMCKit.fanCount()) ?? 0
            for id in 0..<count {
                try? SMCKit.fanSetAuto(id)
            }
            overriddenFans.removeAll()
            return count > 0 ? nil : "no fans"
        } catch {
            return String(describing: error)
        }
    }

    func revertAllSync() {
        queue.sync {
            _ = revertAllLocked()
        }
    }

    func ping(reply: @escaping (String, [Int]) -> Void) {
        queue.async { [self] in
            lastPing = Date()
            reply(FanHelperConstants.version, Array(overriddenFans).sorted())
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let controller: FanController
    private var activeConnections = 0
    private let connectionQueue = DispatchQueue(label: "com.gaosun.eul.helper.connections")

    init(controller: FanController) {
        self.controller = controller
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // only eul may talk to this daemon: kernel-verified signing
        // requirement (Stats shipped a root LPE by skipping this —
        // GHSA-qwhf-px96-7f6v). Matches Apple Development and Developer ID
        // leaf certificates for the team.
        if #available(macOS 13.0, *) {
            connection.setCodeSigningRequirement(
                "anchor apple generic and identifier \"com.gaosun.eul\" and certificate leaf[subject.OU] = \"M8G2RFZVFV\""
            )
        } else {
            // the daemon is only ever registered via SMAppService (13+)
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = controller
        connectionQueue.sync { activeConnections += 1 }
        connection.invalidationHandler = { [weak self] in
            guard let self = self else {
                return
            }
            let remaining: Int = self.connectionQueue.sync {
                self.activeConnections -= 1
                return self.activeConnections
            }
            // the app went away — its fans must not stay pinned
            if remaining <= 0, self.controller.hasOverrides {
                self.controller.revertAllSync()
            }
        }
        connection.resume()
        return true
    }
}

/// a crashed predecessor may have left fans forced — start from a safe state
let controller = FanController()
controller.revertAllSync()

let delegate = ListenerDelegate(controller: controller)
let listener = NSXPCListener(machServiceName: FanHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

/// dead-man watchdog: overrides with no heartbeat for 45 s mean the app died
/// without cleanup (force-quit, crash before invalidation) — revert
let watchdog = DispatchSource.makeTimerSource()
watchdog.schedule(deadline: .now() + 15, repeating: 15)
watchdog.setEventHandler {
    if controller.hasOverrides, controller.secondsSinceLastPing > 45 {
        controller.revertAllSync()
    }
}

watchdog.resume()

signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM)
sigterm.setEventHandler {
    controller.revertAllSync()
    exit(0)
}

sigterm.resume()

RunLoop.main.run()
