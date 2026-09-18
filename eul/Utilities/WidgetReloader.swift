//
//  WidgetReloader.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Foundation
import WidgetKit

/// Coalesces WidgetCenter reload requests. Stores used to reload their widget
/// timelines on every refresh tick (every few seconds), waking every installed
/// widget extension process around the clock — a dominant share of the app's
/// always-on power cost (#76, #87). Requests are skipped entirely when no
/// widget of that kind is installed, and throttled otherwise. The same
/// knowledge gates the producer side via shouldWrite(kind:), so stores skip
/// the container encode + cfprefsd write too when nothing consumes it.
enum WidgetReloader {
    static let minimumReloadInterval: TimeInterval = 15
    private static let configurationRefreshInterval: TimeInterval = 60
    /// heartbeat for uninstalled kinds: keeps the container at most a minute
    /// stale for the widget-gallery snapshot / just-added-widget path
    private static let uninstalledWriteInterval: TimeInterval = 60

    private static let queue = DispatchQueue(label: "eul.widgetReloader", qos: .utility)
    /// guards installedKinds / hasFetchedConfigurations / lastWrite —
    /// shouldWrite runs synchronously on the stores' main thread while the
    /// configuration fetch updates state from the reloader queue
    private static let stateLock = NSLock()
    private static var installedKinds = Set<String>()
    private static var hasFetchedConfigurations = false
    private static var lastWrite = [String: Date]()
    private static var lastConfigurationFetch: Date?
    private static var lastReload = [String: Date]()
    private static var lastReloadAll: Date?

    /// Whether a store should bother encoding its entry into the shared
    /// container this tick. Always true for installed kinds; for uninstalled
    /// kinds writes are throttled to one per minute. Callable from any thread.
    static func shouldWrite(kind: String) -> Bool {
        // keep kind detection alive: when this returns false the store skips
        // requestReload entirely, so the configuration fetch must be kicked
        // here (it self-throttles to one fetch per minute)
        queue.async {
            refreshInstalledKindsIfNeeded()
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        // launch-safe: never skip while installed kinds are still unknown
        guard hasFetchedConfigurations else {
            return true
        }
        if installedKinds.contains(kind) {
            return true
        }
        if let last = lastWrite[kind], Date().timeIntervalSince(last) < uninstalledWriteInterval {
            return false
        }
        lastWrite[kind] = Date()
        return true
    }

    static func requestReload(ofKind kind: String) {
        queue.async {
            refreshInstalledKindsIfNeeded()

            stateLock.lock()
            let isInstalled = installedKinds.contains(kind)
            stateLock.unlock()

            guard isInstalled else {
                return
            }
            if let last = lastReload[kind], Date().timeIntervalSince(last) < minimumReloadInterval {
                return
            }
            lastReload[kind] = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    static func requestReloadAll() {
        queue.async {
            refreshInstalledKindsIfNeeded()

            stateLock.lock()
            let isEmpty = installedKinds.isEmpty
            stateLock.unlock()

            guard !isEmpty else {
                return
            }
            if let last = lastReloadAll, Date().timeIntervalSince(last) < minimumReloadInterval {
                return
            }
            lastReloadAll = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func refreshInstalledKindsIfNeeded() {
        if let last = lastConfigurationFetch, Date().timeIntervalSince(last) < configurationRefreshInterval {
            return
        }
        lastConfigurationFetch = Date()
        WidgetCenter.shared.getCurrentConfigurations { result in
            queue.async {
                guard case let .success(infos) = result else {
                    return
                }
                let new = Set(infos.map { $0.kind })

                stateLock.lock()
                let old = installedKinds
                installedKinds = new
                hasFetchedConfigurations = true
                stateLock.unlock()

                // a kind transitioning to installed gets a fresh write AND
                // reload on the very next tick
                for kind in new.subtracting(old) {
                    lastReload[kind] = nil
                    stateLock.lock()
                    lastWrite[kind] = nil
                    stateLock.unlock()
                }
            }
        }
    }
}
