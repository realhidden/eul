//
//  NetworkWidget.swift
//  NetworkWidget
//
//  Created by Gao Sun on 2020/11/7.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Intents
import Localize_Swift
import SharedLibrary
import SwiftUI
import WidgetKit

struct Provider: StandardProvider {
    typealias WidgetEntry = NetworkEntry
}

struct NetworkWidgetEntryView: View {
    var preferenceEntry = Container.get(PreferenceEntry.self) ?? PreferenceEntry()
    var entry: Provider.Entry

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 5) {
                    Image("Network")
                        .resizable()
                        .frame(width: 12, height: 12)
                        .opacity(0.6)
                    Text("eul")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer(minLength: 6)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ByteUnit(entry.inSpeedInByte).readable + "/s")
                            .widgetDisplayText()
                        HStack(spacing: 3) {
                            Image("Down")
                                .resizable()
                                .frame(width: 9, height: 9)
                            Text("network.in".localized())
                                .font(.system(size: 10))
                                .fixedSize()
                        }
                        .foregroundColor(.thirdary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ByteUnit(entry.outSpeedInByte).readable + "/s")
                            .widgetDisplayText()
                        HStack(spacing: 3) {
                            Image("Up")
                                .resizable()
                                .frame(width: 9, height: 9)
                            Text("network.out".localized())
                                .font(.system(size: 10))
                                .fixedSize()
                        }
                        .foregroundColor(.thirdary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 8)
                WidgetBars(values: entry.history)
                    .frame(height: 32)
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
struct NetworkWidget: Widget {
    let kind: String = NetworkEntry.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            NetworkWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("widget.network.title".localized())
        .description("widget.network.description".localized())
        .supportedFamilies([.systemSmall])
    }
}
