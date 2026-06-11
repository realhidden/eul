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

/// Shared plumbing for eul's two status items. Only ONE is ever visible —
/// the strip (slots + eyes) in normal operation, the eyes-only anchor at the
/// collapse floor — so eul always reads as a single entry point (user
/// feedback: two simultaneous icons were perceived as two apps / a bug).
class BaseStatusItem: NSObject {
    let item: NSStatusItem
    let autosaveNameString: String
    private let contextMenu = NSMenu()

    /// AppKit deletes "NSStatusItem Preferred Position" when an item is
    /// hidden, so the user's dragged position is stashed across hide/show
    /// cycles (#40, #113)
    fileprivate var stashedPosition: Any?

    fileprivate var positionKey: String {
        "NSStatusItem Preferred Position \(autosaveNameString)"
    }

    /// True when the item exists but the system is not drawing it — hidden
    /// for lack of menu bar space (overflow/notch) while isVisible stays
    /// true. occlusionState is NOT trustworthy for status windows (observed
    /// on notched macOS 15: not-visible for items that are plainly in the
    /// bar, visible for items parked offscreen) — the window frame is the
    /// reliable signal. macOS parks an unplaceable item just below the
    /// screen origin at (0, -height); a placed item sits flush with a
    /// screen's top edge.
    var isOccluded: Bool {
        guard item.isVisible, let window = item.button?.window else {
            return false
        }
        let frame = window.frame
        return !NSScreen.screens.contains { screen in
            abs(frame.maxY - screen.frame.maxY) < 1
                && frame.minX >= screen.frame.minX - 1
                && frame.maxX <= screen.frame.maxX + 1
        }
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

    /// Take over the other item's bar position so the strip↔anchor swap
    /// doesn't make the eyes jump across the menu bar; applied by the next
    /// setVisible(true)
    func adoptPosition(from other: BaseStatusItem) {
        let position = other.isVisible
            ? UserDefaults.standard.object(forKey: other.positionKey)
            : other.stashedPosition
        if let position = position {
            stashedPosition = position
        }
    }

    static func preferredPosition(for autosaveName: String) -> Double? {
        UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position \(autosaveName)") as? Double
    }

    /// Left-click opens the panel; right/control-click shows the small
    /// Preferences/Quit menu. Identical on both items.
    @objc fileprivate func handleClick() {
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

    fileprivate func setupButton() {
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
    }

    init(autosaveName: String, length: CGFloat) {
        autosaveNameString = autosaveName
        item = NSStatusBar.system.statusItem(withLength: length)
        super.init()
        item.autosaveName = autosaveName
    }
}

/// The collapse floor (design §2.2): an eyes-only item shown when the strip
/// has nothing to show or won't fit. Identity, health, and the entry point
/// in 28 pt — eul never disappears by its own choice.
class AnchorStatusItem: BaseStatusItem {
    static let autosaveName = "eul.anchor"
    static let itemLength: CGFloat = 28
    static let glyphWidth: CGFloat = 18

    private var hostingView: NSHostingView<AnyView>?
    private var healthCancellable: AnyCancellable?

    init() {
        // first floor entry lands near the strip's saved spot (the items are
        // never visible together; this just keeps the eyes from jumping)
        let anchorKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if
            UserDefaults.standard.object(forKey: anchorKey) == nil,
            let stripPosition = Self.preferredPosition(for: StripStatusItem.autosaveName)
        {
            UserDefaults.standard.set(max(stripPosition - 1, 0), forKey: anchorKey)
        }
        super.init(autosaveName: Self.autosaveName, length: Self.itemLength)
        // visible during the manager's startup window so the bar is never
        // empty; the first renderBar() swaps to the strip when slots exist
        item.isVisible = true

        setupButton()
        render()
        healthCancellable = SharedStore.health.$level.sink { [weak self] level in
            DispatchQueue.main.async {
                self?.render(level: level)
            }
        }
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

/// The primary item: pinned slots + the eyes glyph as one unit, collapsing
/// slot-by-slot under width pressure before swapping to the anchor floor.
/// Keeps the legacy "eul" autosaveName so existing users' saved position
/// survives the upgrade.
class StripStatusItem: BaseStatusItem {
    static let autosaveName = "eul"

    private var statusView: NSHostingView<AnyView>?
    private(set) var slotLimit = Int.max

    init() {
        super.init(autosaveName: Self.autosaveName, length: 0)
        setupButton()
        // start hidden (position-preserving) so an ungoverned full-width
        // strip never flashes at launch; the manager's first renderBar
        // decides visibility ~0.5 s later
        setVisible(false)
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
