//
//  View.swift
//  eul
//
//  Created by Gao Sun on 2020/9/11.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import SwiftUI

/// pointing-hand cursor on hover — the push/pop idiom from
/// HorizontalOrganizingView; the onDisappear pop prevents a stuck cursor
/// when the panel orders out under the pointer
private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !isHovering {
                    isHovering = true
                    NSCursor.pointingHand.push()
                } else if !hovering, isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    isHovering = false
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }

    /// VoiceOver cue for tap-to-expand tiles; gated since the accessibility
    /// modifiers are macOS 11+ and the app floor is 10.15
    @ViewBuilder
    func a11yExpandButton(label: String) -> some View {
        if #available(macOS 11.0, *) {
            accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(label))
        } else {
            self
        }
    }

    func menuInfo() -> some View {
        font(.system(size: 14, weight: .regular))
            .foregroundColor(.info)
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.top, -2)
            .padding(.bottom, 4)
            .fixedSize()
    }

    func menuBlock(radius: CGFloat = 8) -> some View {
        padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.menuBorder.opacity(0.5), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.textBackground)
                            .brightness(0.05)
                            .opacity(0.5)
                            .blur(radius: 2)
                    )
                    .shadow(color: Color.shadow.opacity(0.1), radius: 5)
            )
    }
}
