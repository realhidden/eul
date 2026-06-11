//
//  EulWidgetEntries.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Foundation

// The eul 2.0 widgets (design §6): two instead of four, both honest about
// time. Entries carry their capture timestamp so the relative stamp renders
// without waking the app (ask 9); past 90 s the widget dims its values and
// the stamp becomes the loudest element.

@available(macOSApplicationExtension 11, *)
public struct HealthEntry: SharedWidgetEntry {
    public init(
        date: Date = Date(),
        outdated: Bool = false,
        capturedAt: Date = Date(),
        stale: Bool = false,
        level: Int = 0,
        verdict: String = "",
        cpu: Double? = nil,
        memory: Double? = nil
    ) {
        self.date = date
        self.outdated = outdated
        self.capturedAt = capturedAt
        self.stale = stale
        self.level = level
        self.verdict = verdict
        self.cpu = cpu
        self.memory = memory
    }

    public init(date: Date, outdated: Bool) {
        self.date = date
        self.outdated = outdated
        capturedAt = date
    }

    public static let containerKey = "HealthEntry"
    public static let kind = "EulHealthWidget"
    public static let sample = HealthEntry(verdict: "All systems normal", cpu: 12, memory: 58)

    /// WidgetKit display time — NOT the data age; see capturedAt
    public var date = Date()
    public var outdated = false
    /// when the app sampled the data
    public var capturedAt = Date()
    /// render dimmed, stamp leading (set by the provider past 90 s)
    public var stale = false
    /// HealthLevel raw value: 0 normal / 1 elevated / 2 critical
    public var level = 0
    /// pre-localized in the app's language
    public var verdict = ""
    public var cpu: Double?
    public var memory: Double?
}

@available(macOSApplicationExtension 11, *)
public struct TrendsEntry: SharedWidgetEntry {
    public init(
        date: Date = Date(),
        outdated: Bool = false,
        capturedAt: Date = Date(),
        stale: Bool = false,
        level: Int = 0,
        cpuHistory: [Double] = [],
        memoryHistory: [Double] = [],
        networkHistory: [Double] = [],
        cpuCurrent: String = "",
        memoryCurrent: String = "",
        networkCurrentInByte: Double = 0
    ) {
        self.date = date
        self.outdated = outdated
        self.capturedAt = capturedAt
        self.stale = stale
        self.level = level
        self.cpuHistory = cpuHistory
        self.memoryHistory = memoryHistory
        self.networkHistory = networkHistory
        self.cpuCurrent = cpuCurrent
        self.memoryCurrent = memoryCurrent
        self.networkCurrentInByte = networkCurrentInByte
    }

    public init(date: Date, outdated: Bool) {
        self.date = date
        self.outdated = outdated
        capturedAt = date
    }

    public static let containerKey = "TrendsEntry"
    public static let kind = "EulTrendsWidget"
    public static let sample = TrendsEntry(
        cpuHistory: [12, 14, 11, 18, 22, 16, 13, 12, 15, 19, 14, 12],
        memoryHistory: [55, 56, 58, 57, 58, 59, 58, 58, 57, 58, 58, 58],
        networkHistory: [0.2, 1.4, 2.8, 0.9, 0.4, 3.1, 2.2, 1.1, 0.8, 2.4, 1.9, 1.2],
        cpuCurrent: "12%",
        memoryCurrent: "58%",
        networkCurrentInByte: 2_400_000
    )

    public var date = Date()
    public var outdated = false
    public var capturedAt = Date()
    public var stale = false
    public var level = 0
    /// downsampled 10-minute ring buffers (≤40 points)
    public var cpuHistory: [Double] = []
    public var memoryHistory: [Double] = []
    /// download bytes/s
    public var networkHistory: [Double] = []
    public var cpuCurrent = ""
    public var memoryCurrent = ""
    public var networkCurrentInByte: Double = 0
}
