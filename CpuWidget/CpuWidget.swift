//
//  CpuWidget.swift
//  CpuWidget
//
//  Created by Gao Sun on 2020/11/4.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Intents
import Localize_Swift
import SharedLibrary
import SwiftUI
import WidgetKit

struct Provider: StandardProvider {
    typealias WidgetEntry = CpuEntry
}

struct CpuWidgetEntryView: View {
    var preferenceEntry = Container.get(PreferenceEntry.self) ?? PreferenceEntry()
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 5) {
                    Image("CPU")
                        .resizable()
                        .frame(width: 12, height: 12)
                        .opacity(0.6)
                    Text("eul")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer(minLength: 6)
                Text(entry.usageString)
                    .widgetTitle()
                HStack(spacing: 6) {
                    if let temp = entry.temp {
                        Text(temp.formatTemp(unit: preferenceEntry.temperatureUnit))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    if let usageUser = entry.usageUser, let usageSystem = entry.usageSystem {
                        Text(String(format: "%@ %.0f%% · %@ %.0f%%", "cpu.user".localized(), usageUser, "cpu.system".localized(), usageSystem))
                            .font(.system(size: 10))
                            .foregroundColor(.thirdary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 1)
                Spacer(minLength: 8)
                WidgetBars(values: entry.history)
                    .frame(height: 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            if !entry.isValid {
                WidgetNotAvailbleView(text: "widget.not_available".localized())
            }
        }
        .preferredColorScheme(preferenceEntry.colorScheme)
    }
}

@main
struct CpuWidget: Widget {
    let kind: String = CpuEntry.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            CpuWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget.cpu.title".localized())
        .description("widget.cpu.description".localized())
        .supportedFamilies([.systemSmall])
    }
}
