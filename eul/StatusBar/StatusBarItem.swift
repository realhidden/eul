//
//  StatusBarItem.swift
//  eul
//
//  Created by Gao Sun on 2020/8/21.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Cocoa
import Combine
import SwiftUI

extension Notification.Name {
    static let StatusBarMenuShouldClose = Notification.Name("StatusBarMenuShouldClose")
}

/// Shared plumbing for the two status items of the anchor + strip model
/// (design §2.2 D). Position is enforced by seeding the autosaved position
/// before creation: macOS lays the status area out right-to-left from the
/// clock and hides the leftmost items first, so the item seeded closest to
/// the clock is hidden last.
class BaseStatusItem: NSObject {
    let item: NSStatusItem
    let autosaveNameString: String

    /// AppKit deletes "NSStatusItem Preferred Position" when an item is
    /// hidden, so the user's dragged position is stashed across hide/show
    /// cycles (#40, #113)
    private var stashedPosition: Any?

    private var positionKey: String {
        "NSStatusItem Preferred Position \(autosaveNameString)"
    }

    /// True when the item exists but the system is not drawing it — hidden
    /// for lack of menu bar space (overflow/notch) while isVisible stays true
    var isOccluded: Bool {
        item.button?.window?.occlusionState.contains(.visible) == false
    }

    var isVisible: Bool {
        item.isVisible
    }

    /// Show/hide while preserving the autosaved position: capture it before
    /// hiding (AppKit removes it synchronously), restore it before showing
    func setVisible(_ visible: Bool) {
        if visible {
            if let stashedPosition = stashedPosition {
                UserDefaults.standard.set(stashedPosition, forKey: positionKey)
                self.stashedPosition = nil
            }
            item.isVisible = true
        } else {
            if let current = UserDefaults.standard.object(forKey: positionKey) {
                stashedPosition = current
            }
            item.isVisible = false
        }
    }

    /// Seed "NSStatusItem Preferred Position <name>" only when absent —
    /// smaller = closer to the clock; later user drags are respected
    static func seedPreferredPosition(_ position: CGFloat, autosaveName: String) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(position, forKey: key)
        }
    }

    init(autosaveName: String, length: CGFloat) {
        autosaveNameString = autosaveName
        item = NSStatusBar.system.statusItem(withLength: length)
        super.init()
        item.autosaveName = autosaveName
    }
}

/// The anchor (design §2.2): a fixed-width eyes glyph carrying identity,
/// health state, and the click target into the panel. It never grows and
/// never disappears by eul's choice — the collapse floor is "anchor only".
class AnchorStatusItem: BaseStatusItem {
    static let autosaveName = "eul.anchor"
    static let itemLength: CGFloat = 28
    static let glyphWidth: CGFloat = 18

    private var hostingView: NSHostingView<AnyView>?
    private var healthCancellable: AnyCancellable?
    private let contextMenu = NSMenu()

    init() {
        Self.seedPreferredPosition(0, autosaveName: Self.autosaveName)
        super.init(autosaveName: Self.autosaveName, length: Self.itemLength)
        item.isVisible = true

        let preferencesItem = NSMenuItem(title: "menu.preferences".localized(), action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        contextMenu.addItem(preferencesItem)
        contextMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "menu.quit".localized(), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)

        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        render()
        healthCancellable = SharedStore.health.$level.sink { [weak self] level in
            DispatchQueue.main.async {
                self?.render(level: level)
            }
        }
    }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick {
            // titles are snapshots — refresh in case the language changed
            contextMenu.items.first?.title = "menu.preferences".localized()
            contextMenu.items.last?.title = "menu.quit".localized()
            // a permanently-assigned menu would own left-click too, so assign
            // it only for the duration of this click
            item.menu = contextMenu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            PanelManager.shared.toggle()
        }
    }

    @objc private func openPreferences() {
        AppDelegate.openPreferences()
    }

    @objc private func quit() {
        AppDelegate.quit()
    }

    private func render(level: HealthLevel = SharedStore.health.level) {
        let view = NSHostingView(rootView: AnyView(
            EyesGlyph(state: level.glyphState, width: Self.glyphWidth)
                .frame(width: Self.itemLength, height: AppDelegate.statusBarHeight)
                .allowsHitTesting(false)
        ))
        view.setFrameSize(NSSize(width: Self.itemLength, height: AppDelegate.statusBarHeight))
        item.button?.subviews.forEach { $0.removeFromSuperview() }
        item.button?.addSubview(view)
        hostingView = view
    }
}

/// The strip (design §2.2): one adaptive item holding the pinned slots,
/// collapsing slot-by-slot under width pressure before macOS hides anything.
/// Keeps the legacy "eul" autosaveName so existing users' saved position
/// survives the upgrade.
class StripStatusItem: BaseStatusItem {
    static let autosaveName = "eul"

    private var statusView: NSHostingView<AnyView>?
    private(set) var slotLimit = Int.max

    init() {
        Self.seedPreferredPosition(1, autosaveName: Self.autosaveName)
        super.init(autosaveName: Self.autosaveName, length: 0)
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp])
        // start hidden (position-preserving) so an ungoverned full-width
        // strip never flashes at launch; the manager's first renderStrip
        // decides visibility ~0.5 s later
        setVisible(false)
    }

    @objc private func handleClick() {
        PanelManager.shared.toggle()
    }

    private func onSizeChange(size: CGSize) {
        DispatchQueue.main.async { [self] in
            let width = size.width + 8
            item.length = width
            statusView?.setFrameSize(NSSize(width: width, height: AppDelegate.statusBarHeight))
        }
    }

    func render(slotLimit: Int) {
        self.slotLimit = slotLimit
        let view = NSHostingView(rootView: AnyView(
            StripView(onSizeChange: { [weak self] in self?.onSizeChange(size: $0) }, slotLimit: slotLimit)
                .withGlobalEnvironmentObjects()
        ))
        view.setFrameSize(NSSize(width: 0, height: AppDelegate.statusBarHeight))
        item.button?.subviews.forEach { $0.removeFromSuperview() }
        item.button?.addSubview(view)
        statusView = view
    }
}
