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

/// Orchestrates the anchor + strip pair and runs the width governor
/// (design §2.2–2.3): under width pressure the strip drops slots by priority
/// (last pinned drops first), then disappears entirely; the anchor survives
/// last and, if macOS hides even that, the recovery flow fires (§2.5).
class StatusBarManager {
    static let shared = StatusBarManager()
    private static let launchTime = Date()

    @ObservedObject var preferenceStore = SharedStore.preference
    @ObservedObject var componentsStore = SharedStore.components

    // anchor is created FIRST so the strip inserts to its left (clock-side
    // anchor); on upgrade the anchor is seeded just inside the strip's
    // saved position — see AnchorStatusItem.init
    let anchor = AnchorStatusItem()
    let strip = StripStatusItem()

    private var cancellables = Set<AnyCancellable>()
    private var occlusionObservers: [NSObjectProtocol] = []
    private var governorTimer: Timer?
    private var reprobeTimer: Timer?
    private var hasNotifiedHiddenEpisode = false
    /// governor's current cap on visible slots; reset whenever the user
    /// reconfigures the pinned set or the screen layout changes
    private var slotLimit = Int.max

    init() {
        // w/o the delay items will have a chance of not appearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.subscribe()
        }
    }

    private func subscribe() {
        componentsStore.$activeComponents
            .sink { [weak self] _ in
                // @Published emits on willSet — defer so renderStrip reads
                // the post-assignment store state
                DispatchQueue.main.async {
                    guard let self = self else {
                        return
                    }
                    self.slotLimit = Int.max
                    self.renderStrip()
                    self.checkVisibilityIfNeeded()
                }
            }
            .store(in: &cancellables)

        componentsStore.$showComponents
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.renderStrip()
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
                self?.renderStrip()
                self?.checkVisibilityIfNeeded()
            }
            .store(in: &cancellables)

        observeOcclusion()
        renderStrip()
    }

    private func observeOcclusion() {
        // button windows exist by now (0.5 s after item creation)
        let windows = [anchor.item.button?.window, strip.item.button?.window].compactMap { $0 }
        for window in windows {
            occlusionObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.checkVisibilityIfNeeded()
            })
        }
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

        guard let screen = anchor.item.button?.window?.screen ?? NSScreen.main else {
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

    private func renderStrip() {
        let count = visibleSlotCount
        guard componentsStore.showComponents, count > 0 else {
            strip.setVisible(false)
            return
        }
        strip.render(slotLimit: count)
        if !strip.isVisible {
            strip.setVisible(true)
        }
    }

    private func runGovernor() {
        guard !isMenuBarLikelyHidden else {
            Print("menu bar is hidden (fullscreen/auto-hide), skipping governor")
            return
        }

        let stripDrawnButOccluded = strip.isVisible && strip.isOccluded
        let anchorOccluded = anchor.isOccluded

        if anchorOccluded, stripDrawnButOccluded {
            // usually a display event (lock, lid, monitor switch) — but a bar
            // that fills enough can swallow both items in one re-layout, and
            // that state is stable. Persistence over a re-check means it's
            // real: macOS already draws nothing for us, so dropping slots
            // can't help — go straight to the recovery notification.
            governorTimer?.invalidate()
            governorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                guard
                    let self = self, !self.isMenuBarLikelyHidden,
                    self.anchor.isOccluded, !self.strip.isVisible || self.strip.isOccluded
                else {
                    return
                }
                self.notifyHiddenEpisode()
            }
            return
        }

        if stripDrawnButOccluded {
            // drop the lowest-priority slot; only an off/on toggle makes
            // macOS re-evaluate a hidden item (#149). The toggle preserves
            // the stashed position, and a position-forgotten item re-inserts
            // on the left of our other item, so anchor-right ordering holds.
            slotLimit = max(visibleSlotCount - 1, 0)
            Print("width governor: dropping to \(slotLimit) slot(s)")
            renderStrip()
            if slotLimit > 0 {
                strip.setVisible(false)
                DispatchQueue.main.async { [self] in
                    strip.setVisible(true)
                    checkVisibilityIfNeeded()
                }
            }
            scheduleReprobe()
            return
        }

        if anchorOccluded {
            // the bar is truly full — macOS hid even the anchor. Tell, once,
            // silently (§2.5); the panel stays reachable via relaunch/hotkey.
            notifyHiddenEpisode()
            return
        }

        hasNotifiedHiddenEpisode = false
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
            self.renderStrip()
            self.checkVisibilityIfNeeded()
            self.scheduleReprobe()
        }
    }
}

/// The one notification in the product (design §2.5): posted when macOS
/// hides even the anchor, at most once per occlusion episode, never
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
