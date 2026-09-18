//
//  AppDelegate.swift
//  eul
//
//  Created by Gao Sun on 2020/6/21.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Cocoa
import Combine
import Localize_Swift
import SharedLibrary
import SwiftUI
import UserNotifications

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var isSleeping = false
    // Invalidates pending asyncAfter chains: a brief sleep/wake used to leave
    // the old refresh chain alive next to the new one, multiplying the
    // effective refresh rate after every wake (#76, #18)
    private var refreshGeneration = 0
    private var updateCheckGeneration = 0
    private var updateMethodCancellable: AnyCancellable?
    private var appearanceCancellable: AnyCancellable?
    /// the Settings SwiftUI tree is mounted only while the window is visible
    /// (same pattern as PanelManager); a hidden tree would re-diff on every
    /// store tick around the clock
    private var settingsHostingView: NSHostingView<AnyView>?

    var window: NSWindow!
    @ObservedObject var preferenceStore = SharedStore.preference

    func applicationDidFinishLaunching(_: Notification) {
        // HIG (settings windows): titled, closable and miniaturizable, never
        // resizable/zoomable; the transparent titlebar keeps the rail design
        // while the title still draws
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.center()
        window.setFrameAutosaveName("Eul Preferences")
        // the settings content is fixed-size; override a stale autosaved frame
        window.setContentSize(NSSize(width: 640, height: 560))
        // placeholder until openPreferences mounts ContentView; the fixed
        // frame keeps the non-resizable window's geometry stable
        let hosting = NSHostingView(rootView: AnyView(EmptyView().frame(width: 640, height: 560)))
        settingsHostingView = hosting
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.title = "settings.title".localized()
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self

        // comment out for not showing window at login. no proper solution currently, tracking:
        // https://github.com/sindresorhus/LaunchAtLogin/issues/33
        // window.makeKeyAndOrderFront(nil)
        // NSApp.activate(ignoringOtherApps: true)

        SmcControl.shared.subscribe()
        StatusBarManager.shared.checkVisibilityIfNeeded()
        GlobalHotKey.register()
        // clicking the "eul is hidden" notification must lead somewhere:
        // it opens the panel centered, same as relaunch and the hotkey.
        // Guarded like RecoveryNotifier — UN APIs throw for unbundled builds.
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        wakeUp()

        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            print("😪 going to sleep")
            self.sleep()
        }
        notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            print("🤩 woke up")
            self.wakeUp()
        }
        updateMethodCancellable = preferenceStore.$upgradeMethod.sink { _ in
            DispatchQueue.main.async {
                self.restartUpdateCheck()
            }
        }

        // Disable in Catalina to avoid protential crash
        if #available(OSX 11, *) {
            appearanceCancellable = preferenceStore.$appearanceMode.sink { mode in
                DispatchQueue.main.async {
                    self.window.appearance = mode.nsAppearance
                    NSApp.appearance = mode.nsAppearance
                    PanelManager.shared.setAppearance(mode.nsAppearance)
                }
            }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        print("🤚 should terminate")
        // best-effort; the helper's watchdog covers crashes and force-quits
        SharedStore.fanControl.revertAllOnQuit()
        SmcControl.shared.close()
        return .terminateNow
    }

    /// Recovery flow (§2.5): launching eul while it is already running opens
    /// the panel as a centered window — the path back in when the menu bar
    /// is full and macOS hid even the anchor
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        PanelManager.shared.openCentered()
        return false
    }

    func wakeUp() {
        isSleeping = false
        refreshGeneration += 1
        refreshSMCRepeatedly(generation: refreshGeneration)
        refreshNetworkRepeatedly(generation: refreshGeneration)
        restartUpdateCheck()
    }

    func restartUpdateCheck() {
        updateCheckGeneration += 1
        checkUpdateRepeatedly(generation: updateCheckGeneration)
    }

    func sleep() {
        isSleeping = true
    }

    /// unmount the Settings tree on close so it stops re-diffing on every
    /// store tick; all settings state lives in the stores, so the next
    /// openPreferences remounts pixel-identically
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else {
            return
        }
        settingsHostingView?.rootView = AnyView(EmptyView().frame(width: 640, height: 560))
    }

    func applicationWillTerminate(_: Notification) {
        // Insert code here to tear down your application
    }
}

// MARK: UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive _: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            PanelManager.shared.openCentered()
        }
        completionHandler()
    }
}

// MARK: Static Methods

extension AppDelegate {
    static var statusBarHeight: CGFloat {
        NSStatusBar.system.thickness
    }

    static func openPreferences() {
        let delegate = NSApp.delegate as! AppDelegate
        let window = delegate.window!
        // titles are snapshots — refresh in case the language changed
        window.title = "settings.title".localized()
        // mount the Settings tree on demand (unmounted again on close)
        delegate.settingsHostingView?.rootView = AnyView(ContentView().withGlobalEnvironmentObjects())
        // guard against the placeholder having influenced the frame
        window.setContentSize(NSSize(width: 640, height: 560))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .StatusBarMenuShouldClose, object: nil)
    }

    static func quit() {
        NSApplication.shared.terminate(self)
    }
}

// MARK: Repeating Methods

extension AppDelegate {
    func refreshSMCRepeatedly(generation: Int) {
        guard !isSleeping, generation == refreshGeneration else {
            return
        }

        NotificationCenter.default.post(name: .SMCShouldRefresh, object: nil)
        // tolerance lets the OS coalesce wakeups; .common keeps the re-arm
        // alive while a menu is open or a window is dragged (like asyncAfter)
        let interval = Double(preferenceStore.smcRefreshRate)
        let timer = Timer(timeInterval: interval, repeats: false) { [self] _ in
            refreshSMCRepeatedly(generation: generation)
        }
        timer.tolerance = min(interval * 0.1, 0.5)
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshNetworkRepeatedly(generation: Int) {
        guard !isSleeping, generation == refreshGeneration else {
            return
        }

        NotificationCenter.default.post(name: .NetworkShouldRefresh, object: nil)
        let interval = Double(preferenceStore.networkRefreshRate)
        let timer = Timer(timeInterval: interval, repeats: false) { [self] _ in
            refreshNetworkRepeatedly(generation: generation)
        }
        timer.tolerance = min(interval * 0.1, 0.5)
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkUpdateRepeatedly(generation: Int) {
        guard !isSleeping, generation == updateCheckGeneration, preferenceStore.upgradeMethod != .none else {
            return
        }

        preferenceStore.checkUpdate()
        let timer = Timer(timeInterval: Double(60 * 60), repeats: false) { [self] _ in
            checkUpdateRepeatedly(generation: generation)
        }
        timer.tolerance = Double(60 * 5)
        RunLoop.main.add(timer, forMode: .common)
    }
}
