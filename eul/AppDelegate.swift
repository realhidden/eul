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

    var window: NSWindow!
    @ObservedObject var preferenceStore = SharedStore.preference

    func applicationDidFinishLaunching(_: Notification) {
        let contentView = ContentView()
        // HIG (settings windows): titled, closable and miniaturizable, never
        // resizable/zoomable; the transparent titlebar keeps the rail design
        // while the title still draws
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.center()
        window.setFrameAutosaveName("Eul Preferences")
        // the settings content is fixed-size; override a stale autosaved frame
        window.setContentSize(NSSize(width: 580, height: 520))
        window.contentView = NSHostingView(rootView: contentView.withGlobalEnvironmentObjects())
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
        let window = (NSApp.delegate as! AppDelegate).window!
        // titles are snapshots — refresh in case the language changed
        window.title = "settings.title".localized()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(preferenceStore.smcRefreshRate)) { [self] in
            refreshSMCRepeatedly(generation: generation)
        }
    }

    func refreshNetworkRepeatedly(generation: Int) {
        guard !isSleeping, generation == refreshGeneration else {
            return
        }

        NotificationCenter.default.post(name: .NetworkShouldRefresh, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(preferenceStore.networkRefreshRate)) { [self] in
            refreshNetworkRepeatedly(generation: generation)
        }
    }

    func checkUpdateRepeatedly(generation: Int) {
        guard !isSleeping, generation == updateCheckGeneration, preferenceStore.upgradeMethod != .none else {
            return
        }

        preferenceStore.checkUpdate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(60 * 60)) { [self] in
            checkUpdateRepeatedly(generation: generation)
        }
    }
}
