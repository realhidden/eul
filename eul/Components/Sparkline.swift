//
//  Sparkline.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

/// History ring buffer behind every sparkline (design §10 ask 1):
/// 10 minutes at the refresh cadence, in-memory only, capped sample count.
struct HistoryBuffer {
    static let maxSamples = 300

    private(set) var values: [Double] = []

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > Self.maxSamples {
            values.removeFirst(values.count - Self.maxSamples)
        }
    }
}

/// Monochrome line + 12% fill, truncates at the last real sample (design §7
/// Sparkline). Points append at the refresh cadence; per §5.5 (revised) the
/// line morphs between samples — each point eases toward its new value,
/// reading as a smooth left-scroll. Pass `animation` to enable it; the panel
/// passes a Reduce-Motion-gated animation, while the widget leaves it `nil`
/// (widgets render static timeline snapshots, never tween). Self-contained on
/// purpose: this view compiles into both the app and the widget extension, so
/// it must not reach for app-only motion helpers.
struct Sparkline: View {
    var values: [Double]
    var maxValue: Double
    var color: Color = .primary
    var animation: Animation?

    @State private var displayed: [Double] = []
    /// the y-scale (network's max moves with the data) tweens alongside the
    /// points, so the whole curve morphs rather than the old samples snapping
    /// to a new scale the instant `maxValue` jumps
    @State private var displayedMax: Double = 1

    private var rendered: [Double] {
        displayed.isEmpty ? values : displayed
    }

    private var renderedMax: Double {
        displayed.isEmpty ? maxValue : displayedMax
    }

    var body: some View {
        ZStack {
            SparklineShape(values: rendered, maxValue: renderedMax, closed: true)
                .fill(color.opacity(0.12))
            SparklineShape(values: rendered, maxValue: renderedMax, closed: false)
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .onAppear {
            displayed = values
            displayedMax = maxValue
        }
        .onChange(of: values) { newValues in
            if let animation = animation {
                withAnimation(animation) {
                    displayed = newValues
                    displayedMax = maxValue
                }
            } else {
                displayed = newValues
                displayedMax = maxValue
            }
        }
    }
}

/// The sparkline geometry as a `Shape` so its values can be the `animatableData`
/// — SwiftUI interpolates the array and redraws each frame.
struct SparklineShape: Shape {
    var values: [Double]
    var maxValue: Double
    var closed: Bool

    var animatableData: AnimatablePair<AnimatableVector, Double> {
        get { AnimatablePair(AnimatableVector(values: values), maxValue) }
        set {
            values = newValue.first.values
            maxValue = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, maxValue > 0 else {
            return path
        }
        let stepX = rect.width / CGFloat(values.count - 1)
        // top 2pt of headroom like the prototype (24/26 of height used)
        let usable = rect.height - 2
        let points = values.enumerated().map { index, value -> CGPoint in
            let clamped = CGFloat(min(max(value, 0), maxValue) / maxValue)
            return CGPoint(x: CGFloat(index) * stepX, y: rect.height - usable * clamped)
        }

        if closed {
            path.move(to: CGPoint(x: 0, y: rect.height))
            points.forEach { path.addLine(to: $0) }
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.height))
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
        return path
    }
}

/// Lets a `Shape` interpolate an array of values frame by frame (the sparkline
/// morph). Mismatched lengths — the history buffer grows by one per tick until
/// it caps — pad to the longer with zero, so a freshly appended sample grows in
/// from the baseline rather than popping. Lives here (not in the app-only
/// motion file) because `SparklineShape` is compiled into the widget too.
struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero = AnimatableVector(values: [])

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, +)
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, -)
    }

    private static func combine(
        _ lhs: AnimatableVector,
        _ rhs: AnimatableVector,
        _ op: (Double, Double) -> Double
    ) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let l = index < lhs.values.count ? lhs.values[index] : 0
            let r = index < rhs.values.count ? rhs.values[index] : 0
            result[index] = op(l, r)
        }
        return AnimatableVector(values: result)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}
