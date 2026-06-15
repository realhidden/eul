//
//  AnimatedValue.swift
//  eul
//
//  Created by Gao Sun on 2026/6/15.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import AppKit
import SwiftUI

/// Value-update motion (design §5.5, revised). The 2.0 brief forbade tweening
/// between samples to protect the energy budget; that rule is now relaxed for
/// the **panel only** — it is mounted transiently, so motion costs power only
/// while the user is actively looking. The always-on bar and the widgets still
/// re-render at the refresh cadence with no tweening. Everything here is gated
/// by Reduce Motion (brief §6.8) and keeps numerals tabular so a rolling value
/// never shifts its neighbours.
enum Motion {
    /// Read from AppKit rather than the SwiftUI `accessibilityReduceMotion`
    /// environment value, whose availability is murky on macOS 11. The panel
    /// re-reads this on every value change, so toggling Reduce Motion while the
    /// panel is open takes effect on the next refresh.
    static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

extension Animation {
    /// numbers count to their new value (no overshoot — a percentage settling)
    static let eulRoll = Animation.easeOut(duration: DesignTokens.Timing.valueRoll)
    /// bars, core columns, sparklines interpolate (critically damped, no bounce)
    static let eulTween = Animation.spring(response: 0.3, dampingFraction: 1)
    /// non-numeric text (aux figures, port names, process values) cross-dissolves
    static let eulCrossfade = Animation.easeInOut(duration: DesignTokens.Timing.valueCrossfade)
}

// MARK: - RollingNumber

/// A numeric reading that rolls/counts to its new value when it changes. The
/// caller supplies the raw `Double` and the exact formatter the static string
/// used, so the rolled digits match the snapped rendering everywhere else.
/// Pass tabular fonts (the panel's `DesignTokens.Typo` values are) so the roll
/// never jitters width. `nil` renders `placeholder` and never animates (a lost
/// sensor must not roll up from zero).
struct RollingNumber: View {
    let value: Double?
    let placeholder: String
    let animation: Animation
    let format: (Double) -> String

    init(
        _ value: Double?,
        placeholder: String = "N/A",
        animation: Animation = .eulRoll,
        format: @escaping (Double) -> String
    ) {
        self.value = value
        self.placeholder = placeholder
        self.animation = animation
        self.format = format
    }

    var body: some View {
        RollingValue(value, placeholder: placeholder, animation: animation) {
            Text(format($0))
        }
    }
}

/// The general primitive behind `RollingNumber`: interpolates the value and
/// rebuilds `content` for each in-between number, so a reading composed of
/// several views (e.g. a network rate's value and its de-emphasised unit) stays
/// internally consistent across the roll instead of two views animating on
/// uncoordinated timelines. `nil` renders `placeholder` and never animates (a
/// lost sensor must not roll up from zero).
struct RollingValue<Content: View>: View {
    let value: Double?
    let placeholder: String
    let animation: Animation
    let content: (Double) -> Content

    @State private var displayed: Double
    @State private var hasValue: Bool

    init(
        _ value: Double?,
        placeholder: String = "N/A",
        animation: Animation = .eulRoll,
        @ViewBuilder content: @escaping (Double) -> Content
    ) {
        self.value = value
        self.placeholder = placeholder
        self.animation = animation
        self.content = content
        _displayed = State(initialValue: value ?? 0)
        _hasValue = State(initialValue: value != nil)
    }

    var body: some View {
        Group {
            if hasValue {
                RollingContent(value: displayed, content: content)
            } else {
                Text(placeholder)
            }
        }
        .onChange(of: value) { newValue in
            guard let newValue = newValue else {
                hasValue = false
                return
            }
            // first appearance (or returning from N/A): snap, don't count up
            // from zero
            guard hasValue else {
                displayed = newValue
                hasValue = true
                return
            }
            if Motion.reduceMotionEnabled {
                displayed = newValue
            } else {
                withAnimation(animation) { displayed = newValue }
            }
        }
    }
}

/// `Animatable` leaf: SwiftUI re-evaluates `body` for each interpolated value
/// during the animation, so `content` rebuilds through the in-between numbers.
/// Works on macOS 11+ (no `contentTransition`/`animation(_:value:)`).
private struct RollingContent<Content: View>: View, Animatable {
    var value: Double
    let content: (Double) -> Content

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        content(value)
    }
}

// MARK: - CrossfadeText

/// Non-numeric panel text (tile aux figures, the active port, process values)
/// cross-dissolves on change instead of snapping. Reduce Motion snaps.
struct CrossfadeText: View {
    let text: String
    let animation: Animation

    @State private var shown: String

    init(_ text: String, animation: Animation = .eulCrossfade) {
        self.text = text
        self.animation = animation
        _shown = State(initialValue: text)
    }

    var body: some View {
        Text(shown)
            .id(shown)
            .transition(.opacity)
            .onChange(of: text) { newValue in
                if Motion.reduceMotionEnabled {
                    shown = newValue
                } else {
                    withAnimation(animation) { shown = newValue }
                }
            }
    }
}
