//
//  HealthStore.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Combine
import Foundation
import SharedLibrary
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

    /// the color cue for a metric at this level — nil at normal so surfaces
    /// stay monochrome until something deserves attention (§5.2)
    var accent: Color? {
        switch self {
        case .normal:
            return nil
        case .elevated:
            return DesignTokens.Health.elevated
        case .critical:
            return DesignTokens.Health.critical
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
        case runaway
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
        // §2.4: 1 process > 150% core-eq ≥ 120 s — elevated only, never
        // critical. The 120 s sustain is enforced PER-PROCESS inside
        // rawRunaway (a relay of different hot processes must not trip it);
        // this tracker just debounces one sample and gives a 30 s clear.
        .runaway: SignalTracker(elevatedWindow: 15, criticalWindow: .greatestFiniteMagnitude),
    ]

    @Published var level: HealthLevel = .normal
    /// the signal currently responsible for the level, for verdict text
    @Published var activeSignal: Signal?

    // per-signal enable toggles (design §4.4 Health pane — whether, not when)
    @Published var thermalEnabled = true
    @Published var memoryPressureEnabled = true
    @Published var diskFullEnabled = true
    @Published var runawayEnabled = true

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
        case .thermal, .runaway:
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
        case .runaway:
            // culprit attribution (ask 2): "Runaway process — Xcode"
            return String(format: "health.verdict.runaway".localized(), runawayCulprit ?? "?")
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

    // MARK: runaway process sampling (design §2.4 / ask 6)

    /// rusage_info times are mach ticks on Apple Silicon, nanoseconds on
    /// Intel — the timebase factor normalizes both to nanoseconds
    private static let machTimebaseFactor: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// pid → cumulative CPU seconds at the last sample
    private var processCPUSamples: [pid_t: Double] = [:]
    /// pid → when this process FIRST crossed the threshold and stayed there;
    /// the §2.4 sustain is per-process, so a relay of different briefly-hot
    /// processes cannot trip the signal or misattribute the culprit
    private var overThresholdSince: [pid_t: Date] = [:]
    private var lastRunawaySampleAt: Date?
    private var cachedRunawayLevel: HealthLevel = .normal
    private(set) var runawayCulprit: String?
    /// the trip window is 120 s — sampling every refresh tick would be
    /// wasted syscalls; 15 s gives 8 samples per window
    private static let runawaySampleInterval: TimeInterval = 15
    /// §2.4: 1 process > 150% of one core, normalized (1.0 = one full core)
    private static let runawayCoreEquivalentThreshold = 1.5
    private static let runawaySustainWindow: TimeInterval = 120

    private func rawRunaway() -> HealthLevel {
        let now = Date()
        guard let last = lastRunawaySampleAt else {
            lastRunawaySampleAt = now
            processCPUSamples = Self.sampleProcessCPUSeconds()
            return .normal
        }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= Self.runawaySampleInterval else {
            return cachedRunawayLevel
        }
        lastRunawaySampleAt = now

        let current = Self.sampleProcessCPUSeconds()
        var streaks: [pid_t: Date] = [:]
        for (pid, cpuSeconds) in current {
            guard let previous = processCPUSamples[pid] else {
                continue
            }
            let coreEquivalent = (cpuSeconds - previous) / elapsed
            if coreEquivalent > Self.runawayCoreEquivalentThreshold {
                streaks[pid] = overThresholdSince[pid] ?? now
            }
        }
        // pids that fell below or died drop out of both maps
        overThresholdSince = streaks
        processCPUSamples = current

        if
            let sustained = streaks.min(by: { $0.value < $1.value }),
            now.timeIntervalSince(sustained.value) >= Self.runawaySustainWindow
        {
            cachedRunawayLevel = .elevated
            // culprit persists through the tracker's hysteresis window
            runawayCulprit = Self.processName(sustained.key)
        } else {
            cachedRunawayLevel = .normal
        }
        return cachedRunawayLevel
    }

    private static func sampleProcessCPUSeconds() -> [pid_t: Double] {
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else {
            return [:]
        }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else {
            return [:]
        }

        var result: [pid_t: Double] = [:]
        result.reserveCapacity(Int(filled))
        for index in 0..<Int(filled) {
            let pid = pids[index]
            guard pid > 0 else {
                continue
            }
            // flavor pinned to V4: RUSAGE_INFO_CURRENT floats with the SDK
            // (V6 today) and kernels before macOS 13 reject it with EINVAL,
            // which would silently disable the detector on the 11/12 floor;
            // V4 has both time fields and is supported everywhere we run
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else {
                continue
            }
            let ticks = info.ri_user_time &+ info.ri_system_time
            result[pid] = Double(ticks) * machTimebaseFactor / 1_000_000_000
        }
        return result
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return "pid \(pid)"
        }
        return String(cString: buffer)
    }

    @objc func refresh() {
        let raws: [Signal: HealthLevel] = [
            .thermal: thermalEnabled ? rawThermal() : .normal,
            .memoryPressure: memoryPressureEnabled ? rawMemoryPressure() : .normal,
            .diskFull: diskFullEnabled ? rawDiskFullCached() : .normal,
            .runaway: runawayEnabled ? rawRunaway() : .normal,
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
        writeToContainer()
    }

    /// the eul 2.0 widgets feed off the health engine + ring buffers
    /// (design §6); WidgetReloader coalesces the reload side
    private func writeToContainer() {
        let now = Date()
        // memory total can be 0 for the first tick(s) → NaN percentage
        let memoryReady = SharedStore.memory.total > 0
        Container.set(HealthEntry(
            capturedAt: now,
            level: level.rawValue,
            verdict: verdictText,
            cpu: SharedStore.cpu.usage,
            memory: memoryReady ? SharedStore.memory.usedPercentage : nil
        ))
        WidgetReloader.requestReload(ofKind: HealthEntry.kind)

        Container.set(TrendsEntry(
            capturedAt: now,
            level: level.rawValue,
            cpuHistory: Self.downsample(cpuHistory),
            memoryHistory: Self.downsample(memoryHistory),
            networkHistory: Self.downsample(networkHistory),
            cpuCurrent: SharedStore.cpu.usageString,
            memoryCurrent: memoryReady ? SharedStore.memory.usedPercentageString : "N/A",
            networkCurrentInByte: SharedStore.network.inSpeedInByte,
            ratesInBits: SharedStore.preference.networkRateInBits
        ))
        WidgetReloader.requestReload(ofKind: TrendsEntry.kind)
    }

    /// a medium widget row is ~250 pt wide — 40 points is plenty
    private static func downsample(_ values: [Double], to target: Int = 40) -> [Double] {
        guard values.count > target else {
            return values
        }
        let step = Double(values.count) / Double(target)
        return (0..<target).map { values[Int(Double($0) * step)] }
    }

    private static let maxHistorySamples = 200

    private func appendHistories() {
        /// sampled at the refresh cadence; values may lag one tick behind the
        /// producing stores depending on observer order — fine for sparklines.
        /// Non-finite values (memory % before the first sample) become 0 so
        /// no NaN ever reaches a Path or the widget container.
        func push(_ buffer: inout [Double], _ value: Double) {
            buffer.append(value.isFinite ? value : 0)
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
            "runawayEnabled": runawayEnabled,
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
        if let value = data["runawayEnabled"].bool {
            runawayEnabled = value
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
            .CombineLatest4($thermalEnabled, $memoryPressureEnabled, $diskFullEnabled, $runawayEnabled)
            .dropFirst()
            .sink { [weak self] _, _, _, _ in
                DispatchQueue.main.async {
                    self?.saveToDefaults()
                }
            }
    }
}
