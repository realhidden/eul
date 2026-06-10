//
//  FanHelperProtocol.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Foundation

/// XPC contract between eul and the privileged fan helper daemon.
/// Compiled into both targets — keep it dependency-free.
@objc public protocol FanHelperProtocol {
    /// Force one fan to a target RPM. The helper clamps to the hardware's
    /// real F{id}Mn...F{id}Mx regardless of what the client asks for.
    func setFanForced(id: Int, targetRPM: Double, reply: @escaping (_ errorDescription: String?) -> Void)

    /// Return one fan to system (automatic) management
    func setFanAuto(id: Int, reply: @escaping (_ errorDescription: String?) -> Void)

    /// Return every fan to system management
    func revertAllToAuto(reply: @escaping (_ errorDescription: String?) -> Void)

    /// Dead-man heartbeat: while any override is active the app pings every
    /// few seconds; if pings stop (crash, force-quit), the helper reverts all
    /// fans to auto on its own — "reverts to Auto when eul quits" must be
    /// mechanically true, not best-effort (design ask 16). The reply carries
    /// the helper's actual overridden fan IDs so the app can reconcile its
    /// published state with reality (helper restarts revert-and-forget).
    func ping(reply: @escaping (_ helperVersion: String, _ overriddenFanIDs: [Int]) -> Void)
}

public enum FanHelperConstants {
    public static let machServiceName = "com.gaosun.eul.helper"
    public static let plistName = "com.gaosun.eul.helper.plist"
    public static let version = "1.0"
}
