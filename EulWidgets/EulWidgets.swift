//
//  EulWidgets.swift
//  EulWidgets
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//
//  The eul 2.0 widget set (design §6): Health (small) + Trends (medium),
//  replacing the four legacy static widgets. Both are honest about time —
//  the capture timestamp renders as an auto-updating relative stamp without
//  waking the app, and past 90 s the values recede while the stamp leads.

import SharedLibrary
import SwiftUI
import WidgetKit

// MARK: staleness-aware provider

protocol StaleRenderable {
    var date: Date { get set }
    var capturedAt: Date { get }
    var stale: Bool { get set }
}

extension HealthEntry: StaleRenderable {}
extension TrendsEntry: StaleRenderable {}

/// Two timeline entries: the data as-is now, and the same data re-rendered
/// dim once it turns 90 s old — WidgetKit swaps them without waking anything
struct StalenessProvider<WidgetEntry: SharedWidgetEntry & StaleRenderable>: TimelineProvider {
    func placeholder(in _: Context) -> WidgetEntry {
        Container.get(WidgetEntry.self) ?? WidgetEntry.sample
    }

    private func currentEntry(at now: Date) -> WidgetEntry {
        guard var entry = Container.get(WidgetEntry.self) else {
            // never ran / container cleared: the synthetic capturedAt is
            // meaningless — render the no-data placeholder, fully stale
            var empty = WidgetEntry(outdated: true)
            empty.stale = true
            return empty
        }
        entry.date = now
        entry.stale = now.timeIntervalSince(entry.capturedAt) > 90
        return entry
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview {
            completion(WidgetEntry.sample)
            return
        }
        completion(currentEntry(at: Date()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let now = Date()
        let fresh = currentEntry(at: now)

        var staleEntry = fresh
        staleEntry.stale = true
        staleEntry.date = max(fresh.capturedAt.addingTimeInterval(90), now.addingTimeInterval(1))

        // the app drives reloads through WidgetReloader; the policy is just a
        // backstop so a long-dead app still re-evaluates eventually
        let timeline = Timeline(
            entries: [fresh, staleEntry],
            policy: .after(now.addingTimeInterval(300))
        )
        completion(timeline)
    }
}

// MARK: shared pieces

private func glyphState(forLevel level: Int) -> EyesGlyph.HealthState {
    switch level {
    case 2:
        return .critical
    case 1:
        return .elevated
    default:
        return .normal
    }
}

private struct WidgetHeader: View {
    var title: String
    var level: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
            Spacer()
            EyesGlyph(state: glyphState(forLevel: level), width: 15)
        }
    }
}

/// shown when the container has never been written (eul never ran, or was
/// uninstalled) — a relative stamp on synthetic data would be a lie
private struct NoDataPlaceholder: View {
    var body: some View {
        Text(NSLocalizedString("widget.no_data", comment: ""))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
    }
}

/// relative, auto-updating, no app wake-up (ask 9); past 90 s the values dim
/// and this becomes the loudest element — trust is rebuilt by admitting age
private struct StalenessStamp: View {
    var capturedAt: Date
    var stale: Bool

    var body: some View {
        Text(capturedAt, style: .relative)
            .font(Font.system(size: 9.5).monospacedDigit())
            .foregroundColor(stale ? .primary : .secondary)
            .opacity(stale ? 0.85 : 0.45)
    }
}

// MARK: Health widget (small)

struct HealthWidgetView: View {
    var entry: HealthEntry

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map { String(format: "%.0f%%", $0) } ?? "N/A")
                .font(Font.system(size: 17, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "EUL", level: entry.level)
            if entry.outdated {
                Spacer()
                NoDataPlaceholder()
                Spacer()
            } else {
                Text(entry.verdict)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                    .padding(.top, 8)
                    .opacity(entry.stale ? 0.42 : 1)
                Spacer()
                HStack(spacing: 14) {
                    stat("CPU", entry.cpu)
                    stat("MEM", entry.memory)
                }
                .opacity(entry.stale ? 0.42 : 1)
                StalenessStamp(capturedAt: entry.capturedAt, stale: entry.stale)
                    .padding(.top, 9)
            }
        }
        .padding(14)
    }
}

struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: HealthEntry.kind, provider: StalenessProvider<HealthEntry>()) { entry in
            HealthWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.health.title", comment: ""))
        .description(NSLocalizedString("widget.health.description", comment: ""))
        .supportedFamilies([.systemSmall])
    }
}

// MARK: Trends widget (medium)

struct TrendsWidgetView: View {
    var entry: TrendsEntry

    private func row(_ label: String, _ history: [Double], maxValue: Double, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .leading)
            Sparkline(values: history, maxValue: maxValue)
                .frame(height: 18)
            Text(value)
                .font(Font.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(title: "EUL · TRENDS", level: entry.level)
            if entry.outdated {
                Spacer()
                NoDataPlaceholder()
                Spacer()
            } else {
                VStack(spacing: 6) {
                    row("CPU", entry.cpuHistory, maxValue: 100, value: entry.cpuCurrent)
                    row("MEM", entry.memoryHistory, maxValue: 100, value: entry.memoryCurrent)
                    row(
                        "NET",
                        entry.networkHistory,
                        maxValue: max(entry.networkHistory.max() ?? 1, 1),
                        value: "↓ " + ByteUnit(entry.networkCurrentInByte).readableRate(inBits: entry.ratesInBits ?? false)
                    )
                }
                .padding(.top, 8)
                .opacity(entry.stale ? 0.42 : 1)
                Spacer(minLength: 0)
                StalenessStamp(capturedAt: entry.capturedAt, stale: entry.stale)
                    .padding(.top, 6)
            }
        }
        .padding(14)
    }
}

struct TrendsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrendsEntry.kind, provider: StalenessProvider<TrendsEntry>()) { entry in
            TrendsWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.trends.title", comment: ""))
        .description(NSLocalizedString("widget.trends.description", comment: ""))
        .supportedFamilies([.systemMedium])
    }
}

// MARK: bundle

@main
struct EulWidgets: WidgetBundle {
    var body: some Widget {
        HealthWidget()
        TrendsWidget()
    }
}
