//
//  StatusBarManager.swift
//  eul
//
//  Created by Gao Sun on 2020/8/22.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Combine
import SwiftUI

class StatusBarManager {
    static let shared = StatusBarManager()

    @ObservedObject var preferenceStore = SharedStore.preference
    @ObservedObject var componentsStore = SharedStore.components
    private var activeCancellable: AnyCancellable?
    private var displayCancellable: AnyCancellable?
    private var showComponentsCancellable: AnyCancellable?
    private var showIconCancellable: AnyCancellable?
    private var fontDesignCancellable: AnyCancellable?
    private var appearanceModeCancellable: AnyCancellable?
    private let item = StatusBarItem()

    init() {
        // w/o the delay items will have a chance of not appearing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.subscribe()
        }
    }

    func checkVisibilityIfNeeded() {
        item.checkVisibilityIfNeeded()
    }

    func subscribe() {
        // TO-DO: refactor
        activeCancellable = SharedStore.components.$activeComponents.sink {
            self.render(components: $0)
        }
        displayCancellable = preferenceStore.$textDisplay.sink { _ in
            self.refresh()
        }
        showComponentsCancellable = SharedStore.components.$showComponents.sink { _ in
            self.refresh()
        }
        showIconCancellable = preferenceStore.$showIcon.sink { _ in
            self.refresh()
        }
        fontDesignCancellable = preferenceStore.$fontDesign.sink { _ in
            self.refresh()
        }
        // Disable in Catalina to avoid protential crash
        if #available(OSX 11, *) {
            appearanceModeCancellable = preferenceStore.$appearanceMode.sink { value in
                DispatchQueue.main.async {
                    self.item.setAppearance(value.nsAppearance)
                }
            }
        }
    }

    func refresh() {
        DispatchQueue.main.async {
            self.item.refresh()
        }
    }

    func render(components _: [EulComponent]) {
        // Toggling isVisible off and on makes the system forget the item's
        // saved position (#40, #113), so a plain in-place refresh is the
        // default. But when the system itself has hidden the item for lack of
        // menu bar space (#149 — wide item + notch), only an off/on toggle
        // makes it re-evaluate; the position is already lost in that case, so
        // the toggle is what lets "reduce component count" bring the item back.
        // isMenuBarLikelyHidden filters occlusion caused by fullscreen or
        // menu bar auto-hide — toggling there would lose the position for no
        // gain (the item reappears by itself when the menu bar returns)
        if !item.isVisible || (item.isHiddenBySystem && !item.isMenuBarLikelyHidden) {
            item.isVisible = false
            DispatchQueue.main.async {
                self.item.isVisible = true
                self.refresh()
            }
            return
        }

        DispatchQueue.main.async {
            self.refresh()
        }
    }
}
