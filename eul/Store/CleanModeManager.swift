//
//  CleanModeManager.swift
//  eul
//
//  Created for Clean Mode (hardware wipe).
//

import AppKit
import Combine
import Foundation

/// Clean Mode (hardware wipe): blacks the screen to zero brightness and
/// disables the keyboard so they can be wiped, then restores both together —
/// the user never needs a keyboard key to get back. The exit is mouse-only by
/// design: a press-and-hold gesture held long enough that brushing the trackpad
/// mid-wipe can't trip it, plus an auto-timeout safety net. The CGEventTap dies
/// with the process, so a crash can't strand the keyboard.
///
/// Action-driven (not `Refreshable`) — it runs only while the user is cleaning.
/// Direct-download builds only: a global keyboard-disabling tap and a private
/// brightness symbol can't ship in an App Store / sandboxed build.
final class CleanModeManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// overlay shown: the restoration guide + Start/Cancel (or, if Input
        /// Monitoring is missing, the one-time permission prompt)
        case confirming
        /// keyboard locked; a brief reminder, then the screen goes fully dark
        case active
        /// restoring brightness + keyboard, fading the overlay out
        case exiting
    }

    @Published private(set) var phase: Phase = .idle
    /// confirming variant: Input Monitoring not yet granted, so Start is blocked
    @Published private(set) var needsPermission = false
    /// the "press & hold anywhere to finish" reminder, shown for a beat at the
    /// start of `active` before the screen goes fully dark
    @Published private(set) var reminderVisible = false
    /// 0...1 fill of the ring under the hold-to-exit gesture
    @Published private(set) var holdProgress: Double = 0
    /// auto-timeout countdown; surfaced only once the user starts holding (the
    /// screen is otherwise fully dark)
    @Published private(set) var secondsRemaining = 0

    static let holdDuration: TimeInterval = 2.0
    static let autoTimeout: TimeInterval = 60
    static let reminderDuration: TimeInterval = 2.5

    private let overlay = CleanModeOverlayController()
    private let keyboard = KeyboardLock()
    private let brightness = DisplayBrightness()

    private var holdTimer: Timer?
    private var autoTimer: Timer?
    private var countdownTimer: Timer?
    private var reminderTimer: Timer?
    private var permissionPollTimer: Timer?
    private var lastBrightnessFraction: Double = 0

    var isEngaged: Bool {
        phase != .idle
    }

    /// True only once the screen is dark and ready for the hold-to-exit gesture.
    var acceptsHold: Bool {
        phase == .active && !reminderVisible
    }

    // MARK: - entry / confirmation

    /// Tapped from the panel header or the status-bar context menu. Shows the
    /// confirmation + restoration guide first — nothing dims or locks until the
    /// user taps Start.
    func enter() {
        guard phase == .idle else {
            return
        }
        needsPermission = !KeyboardLock.hasPermission()
        phase = .confirming
        overlay.show(manager: self)
    }

    func cancel() {
        guard phase == .confirming else {
            return
        }
        stopPermissionPolling()
        phase = .idle
        overlay.hide()
    }

    /// Confirming-screen action when permission is missing. The overlay sits at
    /// screen-saver level, so the TCC prompt and the System Settings window
    /// would open *behind* it, invisible — dismiss the overlay first so the
    /// user can actually grant permission, then re-tap Clean when they're back
    /// (nothing is dimmed or locked yet in this state, so there's nothing to
    /// restore).
    func openPermissionSettings() {
        stopPermissionPolling()
        phase = .idle
        overlay.hide()
        KeyboardLock.requestPermission()
        KeyboardLock.openSettings()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            if KeyboardLock.hasPermission() {
                self.needsPermission = false
                self.stopPermissionPolling()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - start cleaning

    /// Lock the keyboard first (so no keystroke lands during the fade), show the
    /// reminder, then dim to black.
    func start() {
        guard phase == .confirming else {
            return
        }
        guard !needsPermission else {
            openPermissionSettings()
            return
        }
        guard keyboard.lock() else {
            // preflight passed but the tap was refused — fall back to the
            // permission path rather than a half-armed clean
            needsPermission = true
            openPermissionSettings()
            return
        }
        stopPermissionPolling()
        brightness.capture()
        phase = .active
        reminderVisible = true
        startAutoTimeout()
        // hold the reminder readable, then fade the backlight to zero
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: Self.reminderDuration, repeats: false) { [weak self] _ in
            guard let self = self, self.phase == .active else {
                return
            }
            self.reminderVisible = false
            self.brightness.ramp(toFraction: 0, duration: 0.5)
        }
    }

    private func startAutoTimeout() {
        secondsRemaining = Int(Self.autoTimeout)
        autoTimer?.invalidate()
        autoTimer = Timer.scheduledTimer(withTimeInterval: Self.autoTimeout, repeats: false) { [weak self] _ in
            self?.exit()
        }
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.secondsRemaining = max(0, self.secondsRemaining - 1)
        }
    }

    // MARK: - hold to exit

    func beginHold() {
        guard acceptsHold, holdTimer == nil else {
            return
        }
        // take direct control of the backlight, cancelling the reminder→dark
        // fade if the user starts holding while it is still running
        brightness.stopRamp()
        // -1 so the very first tick clears the 0.05 throttle and the screen
        // starts tracking the ring immediately (no dead-zone at the start)
        lastBrightnessFraction = -1
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            self.holdProgress = min(1, self.holdProgress + (1.0 / 60.0) / Self.holdDuration)
            // fade the backlight up as the ring fills, so the hold gives
            // feedback and an intentional exit ends on a lit screen; throttle
            // the brightness writes to ~5% steps
            if abs(self.holdProgress - self.lastBrightnessFraction) >= 0.05 {
                self.brightness.setFraction(self.holdProgress)
                self.lastBrightnessFraction = self.holdProgress
            }
            if self.holdProgress >= 1 {
                self.exit()
            }
        }
    }

    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard phase == .active else {
            return
        }
        holdProgress = 0
        lastBrightnessFraction = 0
        // released early → back to fully dark
        brightness.ramp(toFraction: 0, duration: 0.2)
    }

    // MARK: - exit / cleanup

    /// Animated exit (hold complete or auto-timeout). Restores brightness BEFORE
    /// unlocking the keyboard, so the screen is visible the instant keys work.
    func exit() {
        guard phase == .active else {
            return
        }
        phase = .exiting
        invalidateActiveTimers()
        holdProgress = 0
        reminderVisible = false
        brightness.restore()
        keyboard.unlock()
        // let the overlay fade out, then tear it down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else {
                return
            }
            self.overlay.hide()
            self.phase = .idle
        }
    }

    /// Synchronous, no-animation teardown for app termination and the
    /// tap-can't-re-enable path. Order: brightness, keyboard, overlay.
    func forceExit() {
        guard phase != .idle else {
            return
        }
        invalidateActiveTimers()
        stopPermissionPolling()
        holdProgress = 0
        reminderVisible = false
        brightness.restore()
        keyboard.unlock()
        overlay.hide()
        phase = .idle
    }

    private func invalidateActiveTimers() {
        holdTimer?.invalidate()
        holdTimer = nil
        autoTimer?.invalidate()
        autoTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
    }
}
