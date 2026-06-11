//
//  StatusBarManager.swift
//  eul
//
//  Created by Gao Sun on 2020/8/22.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import SwiftUI
import UserNotifications

/// Orchestrates the bar and runs the width governor (design §2.2–2.3).
/// Exactly ONE item is visible at a time — the slots strip normally, the
/// eyes-only anchor at the floor — so eul reads as a single entry point.
/// Under width pressure the strip drops slots by priority (last pinned drops
/// first), then swaps for the anchor; if macOS hides even that, the recovery
/// flow fires (§2.5).
class StatusBarManager {
    static let shared = StatusBarManager()
    private static let launchTime = Date()

    @ObservedObject var preferenceStore = SharedStore.preference
    @ObservedObject var componentsStore = SharedStore.components

    let anchor = AnchorStatusItem()
    let strip = StripStatusItem()

    private var cancellables = Set<AnyCancellable>()
    private var governorTimer: Timer?
    private var reprobeTimer: Timer?
    private var hasNotifiedHiddenEpisode = false
    /// governor's current cap on visible slots; reset whenever the user
    /// reconfigures the pinned set or the screen layout changes
    private var slotLimit = Int.max
    /// Lock screen, display sleep, and system sleep mark EVERY status-item
    /// window occluded. Without this gate the 3 s confirm windows fire across
    /// those periods (queued notifications + stale timers run at wake while
    /// the lock screen is still up) and shred the strip to the floor in
    /// seconds — while recovery crawls back one slot per reprobe. Verdicts
    /// from a screen nobody can see are void.
    private var sessionInactive = false
    /// occlusion readings are unreliable right after launch, wake/unlock,
    /// and visibility transitions (a re-shown item can take a while to be
    /// placed); no verdict is allowed inside the grace window
    private var graceUntil = Date.distantPast

    /// whichever item currently carries eul in the bar
    private var entryItem: BaseStatusItem {
        strip.isVisible ? strip : anchor
    }

    var entryButton: NSStatusBarButton? {
        entryItem.item.button
    }

    var entryWindow: NSWindow? {
        entryItem.item.button?.window
    }

    var entryItemOccluded: Bool {
        entryItem.isOccluded
    }

    init() {
        graceUntil = Date().addingTimeInterval(15)
        // w/o the delay items will have a chance of not appearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.subscribe()
        }
    }

    /// Wake/unlock: void any pressure verdicts reached against a dead screen
    /// and give the full strip a fresh chance — if the bar is genuinely
    /// tight, the governor will re-collapse it, correctly this time
    private func sessionBecameActive() {
        sessionInactive = false
        graceUntil = max(graceUntil, Date().addingTimeInterval(15))
        slotLimit = Int.max
        renderBar()
        checkVisibilityIfNeeded()
    }

    /// no occlusion verdict while the session is dark or inside a grace
    /// window — readings there are artifacts, not width pressure
    private var occlusionVerdictAllowed: Bool {
        !sessionInactive && Date() >= graceUntil
    }

    private func subscribe() {
        componentsStore.$activeComponents
            .sink { [weak self] _ in
                // @Published emits on willSet — defer so renderBar reads
                // the post-assignment store state
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }
                    self.slotLimit = Int.max
                    self.renderBar()
                    self.checkVisibilityIfNeeded()
                }
            }
            .store(in: &cancellables)

        componentsStore.$showComponents
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderBar()
                }
            }
            .store(in: &cancellables)

        if #available(OSX 11, *) {
            preferenceStore.$appearanceMode
                .sink { value in
                    DispatchQueue.main.async {
                        PanelManager.shared.setAppearance(value.nsAppearance)
                    }
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                // display layout changed: pressure may have eased — start over
                self?.slotLimit = Int.max
                self?.renderBar()
                self?.checkVisibilityIfNeeded()
            }
            .store(in: &cancellables)

        // override start/stop changes what the strip must show (FAN auto-pin)
        SharedStore.fanControl.$overrides
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderBar()
                }
            }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionInactive = true
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionBecameActive()
            }
        }
        // lock/unlock has no NSWorkspace equivalent; these names are
        // long-stable public-by-convention distributed notifications
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionInactive = true
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.sessionBecameActive()
        }

        // space changes alter what fits (fullscreen spaces, displays joining)
        // — give the full strip a fresh probe instead of waiting for the
        // 5-minute reprobe
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.slotLimit < self.componentsStore.activeComponents.count else {
                return
            }
            self.slotLimit = Int.max
            self.renderBar()
            self.checkVisibilityIfNeeded()
        }

        // observe all windows and filter — button windows are recreated by
        // visibility toggles, so observing specific instances would go blind.
        // didMove is the primary signal (parking/placing an item moves its
        // window); occlusion changes are kept as a secondary nudge.
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self = self,
                    let window = notification.object as? NSWindow,
                    window === self.anchor.item.button?.window || window === self.strip.item.button?.window
                else {
                    return
                }
                self.checkVisibilityIfNeeded()
            }
        }

        renderBar()
    }

    /// The occlusion check false-positives whenever the menu bar itself is
    /// hidden — a fullscreen app or the auto-hide setting (#149, #119, #95).
    /// Fullscreen is reported through the system presentation options. The
    /// visibleFrame fallback must subtract the camera-housing inset: AppKit
    /// reserves that row permanently on notched Macs, so visibleFrame.maxY
    /// never reaches frame.maxY there even with the menu bar hidden.
    var isMenuBarLikelyHidden: Bool {
        let options = NSApplication.shared.currentSystemPresentationOptions
        if options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar) {
            return true
        }

        guard let screen = entryWindow?.screen ?? NSScreen.main else {
            return false
        }
        var reservedTop: CGFloat = 0
        if #available(macOS 12.0, *) {
            reservedTop = screen.safeAreaInsets.top
        }
        return screen.visibleFrame.maxY >= screen.frame.maxY - reservedTop
    }

    /// Debounced entry point — called on occlusion changes, component
    /// changes, and at launch (with a grace period against launch-time
    /// false alarms). Always runs: the governor IS the recovery mechanism;
    /// only the notification is gated on the user preference.
    func checkVisibilityIfNeeded() {
        let interval = max(15 + Self.launchTime.timeIntervalSinceNow, 1.5)
        governorTimer?.invalidate()
        governorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.runGovernor()
        }
    }

    private var visibleSlotCount: Int {
        min(slotLimit, componentsStore.activeComponents.count)
    }

    /// strip mode = any slot to show; otherwise the eyes-only floor
    private var wantsStrip: Bool {
        (componentsStore.showComponents && visibleSlotCount > 0)
            // an active fan override keeps the strip alive — the auto-pinned
            // FAN slot must be impossible to forget (design §2.7)
            || SharedStore.fanControl.overrideActive
    }

    private func renderBar() {
        if wantsStrip {
            strip.render(slotLimit: visibleSlotCount)
            if !strip.isVisible {
                strip.adoptPosition(from: anchor)
                strip.setVisible(true)
                noteVisibilityTransition()
            }
            if anchor.isVisible {
                anchor.setVisible(false)
            }
        } else {
            if !anchor.isVisible {
                anchor.adoptPosition(from: strip)
                anchor.setVisible(true)
                noteVisibilityTransition()
            }
            if strip.isVisible {
                strip.setVisible(false)
            }
        }
    }

    /// a just-(re)shown item can report occluded until macOS actually places
    /// it; acting on that reading would cascade drops the bar never asked for
    private func noteVisibilityTransition() {
        graceUntil = max(graceUntil, Date().addingTimeInterval(10))
    }

    private func runGovernor() {
        guard !sessionInactive else {
            // the unlock/wake handler re-kicks the governor
            return
        }
        guard occlusionVerdictAllowed else {
            // inside a grace window — re-check once it has passed
            governorTimer?.invalidate()
            governorTimer = Timer.scheduledTimer(
                withTimeInterval: max(graceUntil.timeIntervalSinceNow, 1.5),
                repeats: false
            ) { [weak self] _ in
                self?.runGovernor()
            }
            return
        }
        guard !isMenuBarLikelyHidden else {
            Print("menu bar is hidden (fullscreen/auto-hide), skipping governor")
            return
        }

        if strip.isVisible, strip.isOccluded {
            // confirm before acting: lid close, screen lock, and monitor
            // switches all false-positive occlusion briefly
            confirm(after: 3) { [weak self] in
                guard
                    let self = self, self.occlusionVerdictAllowed, !self.isMenuBarLikelyHidden,
                    self.strip.isVisible, self.strip.isOccluded
                else {
                    return
                }
                self.dropSlot()
            }
            return
        }

        if anchor.isVisible, anchor.isOccluded {
            // the bar is truly full — macOS hid even the 28 pt floor.
            // Persistence over a longer re-check separates that from display
            // events; then tell, once, silently (§2.5) — the panel stays
            // reachable via relaunch/hotkey.
            confirm(after: 10) { [weak self] in
                guard
                    let self = self, self.occlusionVerdictAllowed, !self.isMenuBarLikelyHidden,
                    self.anchor.isVisible, self.anchor.isOccluded
                else {
                    return
                }
                self.notifyHiddenEpisode()
            }
            return
        }

        hasNotifiedHiddenEpisode = false
    }

    private func confirm(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        governorTimer?.invalidate()
        governorTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            action()
        }
    }

    private func dropSlot() {
        // an override-pinned strip at zero governed slots IS the floor —
        // there is nothing left to drop, so a persistent occlusion here is
        // the hidden-bar case, not width pressure (otherwise the toggle
        // below would loop forever and the notification would never fire)
        guard visibleSlotCount > 0 else {
            confirm(after: 10) { [weak self] in
                guard
                    let self = self, self.occlusionVerdictAllowed, !self.isMenuBarLikelyHidden,
                    self.strip.isVisible, self.strip.isOccluded
                else {
                    return
                }
                self.notifyHiddenEpisode()
            }
            return
        }

        // drop the lowest-priority slot; only an off/on toggle makes macOS
        // re-evaluate a hidden item (#149). The toggle preserves the stashed
        // position. At zero slots renderBar swaps to the 28 pt anchor floor.
        slotLimit = max(visibleSlotCount - 1, 0)
        Print("width governor: dropping to \(slotLimit) slot(s)")
        renderBar()
        if strip.isVisible {
            strip.setVisible(false)
            DispatchQueue.main.async { [self] in
                // the mode may have flipped between the hide and this re-show
                if wantsStrip {
                    strip.setVisible(true)
                    noteVisibilityTransition()
                } else {
                    renderBar()
                }
                checkVisibilityIfNeeded()
            }
        } else {
            checkVisibilityIfNeeded()
        }
        scheduleReprobe()
    }

    private func notifyHiddenEpisode() {
        guard !hasNotifiedHiddenEpisode else {
            return
        }
        hasNotifiedHiddenEpisode = true
        // the preference gates only the user-facing notification, never the
        // governor itself (1.x semantics: the alert was optional, recovery
        // was not)
        if preferenceStore.checkStatusItemVisibility {
            RecoveryNotifier.postHiddenNotification()
        }
    }

    /// Try restoring one dropped slot after pressure may have eased; at most
    /// one probe per interval so a persistently tight bar cannot flap
    private func scheduleReprobe() {
        reprobeTimer?.invalidate()
        reprobeTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            guard let self = self, self.slotLimit < self.componentsStore.activeComponents.count else {
                return
            }
            self.slotLimit += 1
            self.renderBar()
            self.checkVisibilityIfNeeded()
            self.scheduleReprobe()
        }
    }
}

/// The one notification in the product (design §2.5): posted when macOS
/// hides even the floor item, at most once per occlusion episode, never
/// focus-stealing. Replaces the 1.x modal alert.
enum RecoveryNotifier {
    static func postHiddenNotification() {
        // UN APIs require a bundled app; unbundled processes throw an ObjC
        // exception Swift cannot catch (bundleProxyForCurrentProcess)
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Print("not a bundled app, skipping hidden notification")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted {
                        deliver()
                    }
                }
            case .authorized, .provisional:
                deliver()
            default:
                // denied or unavailable (e.g. ad-hoc build not registered):
                // degrade silently — the hotkey and relaunch paths remain
                break
            }
        }
    }

    private static func deliver() {
        let content = UNMutableNotificationContent()
        content.title = "notification.hidden.title".localized()
        content.body = "notification.hidden.body".localized()
        let request = UNNotificationRequest(identifier: "eul.hidden", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Print("notification delivery failed:", error.localizedDescription)
            }
        }
    }
}
