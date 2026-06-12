//
//  SettingsComponents.swift
//  eul
//
//  Created by Gao Sun on 2026/6/11.
//  Copyright © 2026 Gao Sun. All rights reserved.
//
//  Settings primitives in the panel's design language (design §4.4/§5):
//  tile-style cards, labeled rows with trailing controls, and the same
//  segmented pill the panel uses for its lens picker. Settings choose among
//  good states (P5) — these pieces deliberately offer no layout freedom.

import SwiftUI

enum Settings {
    static let secondary = Color.primary.opacity(0.55)

    /// section card — same surface as a panel tile
    struct Card<Content: View>: View {
        var title: String?
        @ViewBuilder var content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let title = title {
                    Text(title.uppercased())
                        .font(DesignTokens.Typo.tileLabel)
                        .tracking(0.6)
                        .foregroundColor(secondary)
                }
                content()
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Panel.tileRadius)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    /// hairline between rows inside a card (the panel's tile divider)
    struct RowDivider: View {
        var body: some View {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
        }
    }

    /// title (+ optional plain-language caption) leading, control trailing
    struct Row<Trailing: View>: View {
        var title: String
        var caption: String?
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption = caption {
                        Text(caption)
                            .font(.system(size: 10.5))
                            .foregroundColor(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                // the control always gets its natural width — when space is
                // tight the TITLE wraps, never the control ("10s" rendering
                // as a vertical column of glyphs is a bug, a two-line title
                // is not)
                trailing()
                    .fixedSize()
            }
            .padding(.vertical, 5)
        }
    }

    struct ToggleRow: View {
        var title: String
        var caption: String?
        @Binding var isOn: Bool

        var body: some View {
            Row(title: title, caption: caption) {
                Toggle("", isOn: $isOn)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }

    /// the panel's segmented pill (lens picker), generic over options
    struct Segmented<Value: Hashable>: View {
        var options: [Value]
        var label: (Value) -> String
        @Binding var selection: Value

        var body: some View {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    Button(action: {
                        selection = option
                    }) {
                        Text(label(option))
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(selection == option ? Color.primary.opacity(0.15) : Color.clear)
                            .cornerRadius(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .pointingHandCursor()
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(7)
        }
    }

    /// quiet underlined text button (panel idiom for secondary actions)
    struct QuietButton: View {
        var title: String
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 10.5))
                    .underline()
                    .foregroundColor(secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .pointingHandCursor()
        }
    }

    /// per-pane "Reset to defaults" (design §4.7): every personalization is
    /// a deviation you can see and undo
    struct ResetRow: View {
        var action: () -> Void

        var body: some View {
            HStack {
                Spacer()
                QuietButton(title: "settings.reset".localized(), action: action)
            }
            .padding(.top, 2)
        }
    }
}
