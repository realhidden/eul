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
/// widget of that kind is installed, and throttled otherwise.
enum WidgetReloader {
    static let minimumReloadInterval: TimeInterval = 15
    private static let configurationRefreshInterval: TimeInterval = 60

    private static let queue = DispatchQueue(label: "eul.widgetReloader", qos: .utility)
    private static var installedKinds = Set<String>()
    private static var lastConfigurationFetch: Date?
    private static var lastReload = [String: Date]()
    private static var lastReloadAll: Date?

    static func requestReload(ofKind kind: String) {
        queue.async {
            refreshInstalledKindsIfNeeded()

            guard installedKinds.contains(kind) else {
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

            guard !installedKinds.isEmpty else {
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
                if case let .success(infos) = result {
                    installedKinds = Set(infos.map { $0.kind })
                }
            }
        }
    }
}
