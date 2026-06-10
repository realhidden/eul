//
//  HealthStore.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import SwiftUI
import SwiftyJSON

/// Aggregate health level — drives the anchor glyph (design §2.4):
/// normal = monochrome, elevated = amber right eye, critical = red both eyes.
enum HealthLevel: Int, Comparable {
    case normal = 0
    case elevated = 1
    case critical = 2

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var glyphState: EyesGlyph.HealthState {
        switch self {
        case .normal:
            return .normal
        case .elevated:
            return .elevated
        case .critical:
            return .critical
        }
    }
}

/// The health engine (design §2.4, ask 2): per-signal thresholds with
/// sustained windows and 2× hysteresis, so a single noisy sample can never
/// flap the glyph. Signals: OS thermal pressure, OS memory-pressure level,
/// boot-disk-full. The runaway-process trigger is deferred — its collector
/// (`top`) only runs while the panel is open (the open-only contract), so it
/// cannot feed an always-on signal without breaking the energy budget.
class HealthStore: ObservableObject, Refreshable {
    /// One signal's trip/clear state machine: trips after the raw condition
    /// holds for its window, clears after it stays below for twice that.
    class SignalTracker {
        let elevatedWindow: TimeInterval
        let criticalWindow: TimeInterval

        private var elevatedCandidateSince: Date?
        private var criticalCandidateSince: Date?
        private var belowSince: Date?
        private(set) var level: HealthLevel = .normal

        init(elevatedWindow: TimeInterval, criticalWindow: TimeInterval) {
            self.elevatedWindow = elevatedWindow
            self.criticalWindow = criticalWindow
        }

        func update(raw: HealthLevel, now: Date = Date()) -> HealthLevel {
            if raw >= .critical {
                if criticalCandidateSince == nil {
                    criticalCandidateSince = now
                }
            } else {
                criticalCandidateSince = nil
            }
            if raw >= .elevated {
                if elevatedCandidateSince == nil {
                    elevatedCandidateSince = now
                }
                belowSince = nil
            } else {
                elevatedCandidateSince = nil
                if belowSince == nil {
                    belowSince = now
                }
            }

            if let since = criticalCandidateSince, now.timeIntervalSince(since) >= criticalWindow {
                level = .critical
            } else if let since = elevatedCandidateSince, now.timeIntervalSince(since) >= elevatedWindow, level < .elevated {
                level = .elevated
            }

            // hysteresis: hold the tripped level until the signal stays below
            // threshold for twice the window that tripped it
            if level > .normal, raw == .normal, let since = belowSince {
                let clearWindow = 2 * (level == .critical ? criticalWindow : elevatedWindow)
                if now.timeIntervalSince(since) >= clearWindow {
                    level = .normal
                }
            } else if level == .critical, raw == .elevated {
                // critical decays to elevated once the critical condition is
                // gone for 2× its window; elevated then clears on its own
                if criticalCandidateSince == nil, let since = lastBelowCritical, now.timeIntervalSince(since) >= 2 * criticalWindow {
                    level = .elevated
                }
            }

            if raw < .critical {
                if lastBelowCritical == nil {
                    lastBelowCritical = now
                }
            } else {
                lastBelowCritical = nil
            }

            return level
        }

        private var lastBelowCritical: Date?
    }

    enum Signal: String, CaseIterable {
        case thermal
        case memoryPressure
        case diskFull
    }

    private let userDefaultsKey = "health"
    private var saveCancellable: AnyCancellable?

    private var trackers: [Signal: SignalTracker] = [
        // §2.4: thermal moderate ≥ 30 s / heavy ≥ 10 s
        .thermal: SignalTracker(elevatedWindow: 30, criticalWindow: 10),
        // §2.4: OS "warn" ≥ 30 s / "critical" ≥ 10 s
        .memoryPressure: SignalTracker(elevatedWindow: 30, criticalWindow: 10),
        // disk changes slowly; short windows just guard against transient reads
        .diskFull: SignalTracker(elevatedWindow: 10, criticalWindow: 10),
    ]

    @Published var level: HealthLevel = .normal
    /// the signal currently responsible for the level, for verdict text
    @Published var activeSignal: Signal?

    // per-signal enable toggles (design §4.4 Health pane — whether, not when)
    @Published var thermalEnabled = true
    @Published var memoryPressureEnabled = true
    @Published var diskFullEnabled = true

    // MARK: history ring buffers (design §10 ask 1 — 10 min, in-memory only)

    @Published var cpuHistory: [Double] = []
    @Published var gpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    /// download speed in bytes/s
    @Published var networkHistory: [Double] = []

    var glyphState: EyesGlyph.HealthState {
        level.glyphState
    }

    /// which panel tile should carry the abnormal treatment
    var abnormalComponent: EulComponent? {
        switch activeSignal {
        case .thermal:
            return .CPU
        case .memoryPressure:
            return .Memory
        case .diskFull:
            return .Disk
        case nil:
            return nil
        }
    }

    var verdictText: String {
        switch activeSignal {
        case .thermal:
            return "health.verdict.thermal".localized()
        case .memoryPressure:
            return "health.verdict.memory".localized()
        case .diskFull:
            return "health.verdict.disk".localized()
        case nil:
            return "health.verdict.normal".localized()
        }
    }

    // MARK: raw signal reads

    /// thermalState → macOS "thermal pressure" terms: .fair = Moderate,
    /// .serious = Heavy, .critical = Trapping. §2.4: moderate ≥ 30 s trips
    /// elevated, heavy ≥ 10 s trips critical.
    private func rawThermal() -> HealthLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .critical, .serious:
            return .critical
        case .fair:
            return .elevated
        default:
            return .normal
        }
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal / 2 warn / 4 critical.
    /// Shipped-and-stable since 10.9 but not formally documented — default to
    /// normal on any failure.
    private func rawMemoryPressure() -> HealthLevel {
        var pressureLevel: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &size, nil, 0) == 0 else {
            return .normal
        }
        switch pressureLevel {
        case 4:
            return .critical
        case 2:
            return .elevated
        default:
            return .normal
        }
    }

    private var cachedDiskLevel: HealthLevel = .normal
    private var diskLevelReadAt: Date?
    /// the ImportantUsage capacity query is an XPC round-trip — too heavy
    /// for every refresh tick; disk fullness moves slowly, 30 s is plenty
    private static let diskReadInterval: TimeInterval = 30

    private func rawDiskFullCached() -> HealthLevel {
        let now = Date()
        if let readAt = diskLevelReadAt, now.timeIntervalSince(readAt) < Self.diskReadInterval {
            return cachedDiskLevel
        }
        diskLevelReadAt = now
        cachedDiskLevel = rawDiskFull()
        return cachedDiskLevel
    }

    /// §2.4: elevated < 10% or < 15 GB free; critical < 3% or < 4 GB.
    /// Reads the boot volume directly so the signal works even when no disk
    /// component is pinned (DiskStore gates its refresh on configuration).
    private func rawDiskFull() -> HealthLevel {
        let url = URL(fileURLWithPath: "/")
        guard
            let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
            let total = values.volumeTotalCapacity, total > 0,
            let free = values.volumeAvailableCapacityForImportantUsage, free >= 0
        else {
            return .normal
        }
        let freeFraction = Double(free) / Double(total)
        let freeGB = Double(free) / 1_000_000_000
        if freeFraction < 0.03 || freeGB < 4 {
            return .critical
        }
        if freeFraction < 0.1 || freeGB < 15 {
            return .elevated
        }
        return .normal
    }

    @objc func refresh() {
        let raws: [Signal: HealthLevel] = [
            .thermal: thermalEnabled ? rawThermal() : .normal,
            .memoryPressure: memoryPressureEnabled ? rawMemoryPressure() : .normal,
            .diskFull: diskFullEnabled ? rawDiskFullCached() : .normal,
        ]

        var newLevel = HealthLevel.normal
        var newActive: Signal?
        for signal in Signal.allCases {
            let tracked = trackers[signal]?.update(raw: raws[signal] ?? .normal) ?? .normal
            if tracked > newLevel {
                newLevel = tracked
                newActive = signal
            }
        }

        if newLevel != level {
            level = newLevel
        }
        if newActive != activeSignal {
            activeSignal = newActive
        }

        appendHistories()
    }

    private static let maxHistorySamples = 200

    private func appendHistories() {
        /// sampled at the refresh cadence; values may lag one tick behind the
        /// producing stores depending on observer order — fine for sparklines
        func push(_ buffer: inout [Double], _ value: Double) {
            buffer.append(value)
            if buffer.count > Self.maxHistorySamples {
                buffer.removeFirst(buffer.count - Self.maxHistorySamples)
            }
        }
        push(&cpuHistory, SharedStore.cpu.usage ?? 0)
        push(&gpuHistory, SharedStore.gpu.usageAverage ?? 0)
        push(&memoryHistory, SharedStore.memory.usedPercentage)
        push(&networkHistory, SharedStore.network.inSpeedInByte)
    }

    // MARK: persistence (repo convention: SwiftyJSON blob in UserDefaults)

    var json: JSON {
        JSON([
            "thermalEnabled": thermalEnabled,
            "memoryPressureEnabled": memoryPressureEnabled,
            "diskFullEnabled": diskFullEnabled,
        ])
    }

    private func loadFromDefaults() {
        guard
            let raw = UserDefaults.standard.data(forKey: userDefaultsKey),
            let data = try? JSON(data: raw)
        else {
            return
        }
        if let value = data["thermalEnabled"].bool {
            thermalEnabled = value
        }
        if let value = data["memoryPressureEnabled"].bool {
            memoryPressureEnabled = value
        }
        if let value = data["diskFullEnabled"].bool {
            diskFullEnabled = value
        }
    }

    private func saveToDefaults() {
        if let data = try? json.rawData() {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    init() {
        loadFromDefaults()
        // docs: thermalState must be read once before the change notification
        // is delivered; refresh() below does that
        initObserver(for: .StoreShouldRefresh)
        refresh()
        // persist only the toggles — objectWillChange fires on every history
        // append (every refresh tick) and would write UserDefaults constantly
        saveCancellable = Publishers
            .CombineLatest3($thermalEnabled, $memoryPressureEnabled, $diskFullEnabled)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                DispatchQueue.main.async {
                    self?.saveToDefaults()
                }
            }
    }
}
