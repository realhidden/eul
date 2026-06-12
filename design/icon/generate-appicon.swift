//
//  eul app icon generator — renders the eul 2.0 mark into AppIcon PNGs.
//  Run: swift eul_icon_render.swift <output dir>
//
//  Design: the panel tile distilled. Apple icon grid (squircle 824/1024,
//  continuous corners, radius 0.225 × box), near-black flat surface with the
//  tile's hairline stroke, and the EyesGlyph at its exact production
//  geometry (20×12 design box: ring r 4.2u, pupil r 1.5u, stroke 1.5u,
//  centers at 6u/14u) in normal state — monochrome at rest, like the product.
//

import AppKit
import SwiftUI

struct IconView: View {
    let px: CGFloat

    // Apple macOS icon grid: shape is 824/1024 of the canvas
    private var box: CGFloat { px * 0.8047 }
    private var cornerRadius: CGFloat { box * 0.225 }

    // small sizes need a bigger mark and a stroke floor to stay legible
    private var glyphWidth: CGFloat { box * (px <= 32 ? 0.74 : 0.60) }
    private var unit: CGFloat { glyphWidth / 20 }
    private var ringRadius: CGFloat { 4.2 * unit }
    private var pupilRadius: CGFloat { max(1.5 * unit, 0.6) }
    private var strokeWidth: CGFloat { max(1.5 * unit, 1.1) }

    private var surfaceTop: Color { Color(.sRGB, red: 0.118, green: 0.118, blue: 0.129) }
    private var surfaceBottom: Color { Color(.sRGB, red: 0.075, green: 0.075, blue: 0.086) }
    private var ink: Color { Color(.sRGB, red: 0.913, green: 0.913, blue: 0.922) }

    private func eye(offsetX: CGFloat, knockout: Bool) -> some View {
        ZStack {
            if knockout {
                // the right eye sits in front (canon: its elevated-state fill
                // occludes the left ring) — knock out the crossing stroke
                Circle()
                    .fill(Color(.sRGB, red: 0.098, green: 0.098, blue: 0.110))
                    .frame(width: ringRadius * 2 + strokeWidth, height: ringRadius * 2 + strokeWidth)
            }
            Circle()
                .strokeBorder(ink, lineWidth: strokeWidth)
                .frame(width: ringRadius * 2 + strokeWidth, height: ringRadius * 2 + strokeWidth)
            Circle()
                .fill(ink)
                .frame(width: pupilRadius * 2, height: pupilRadius * 2)
        }
        .offset(x: offsetX)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [surfaceTop, surfaceBottom],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: box, height: box)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: max(px * 0.0059, 0.5))
                .frame(width: box, height: box)
            // centers at 6u/14u in the 20u box -> ±4u around center;
            // tiny optical lift so the mark doesn't read low
            eye(offsetX: -4 * unit, knockout: false)
                .offset(y: -px * 0.008)
            eye(offsetX: 4 * unit, knockout: true)
                .offset(y: -px * 0.008)
        }
        .frame(width: px, height: px)
    }
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

let files: [(name: String, px: CGFloat)] = [
    ("eul@16px.png", 16),
    ("eul@32px.png", 32), ("eul@32px-1.png", 32),
    ("eul@64px.png", 64),
    ("eul@128px.png", 128),
    ("eul@256px.png", 256), ("eul@256px-1.png", 256),
    ("eul@512px.png", 512), ("eul@512px-1.png", 512),
    ("eul@1024px.png", 1024),
]

@MainActor
func renderAll() {
    var rendered: [CGFloat: Data] = [:]
    for (name, px) in files {
        if rendered[px] == nil {
            let renderer = ImageRenderer(content: IconView(px: px))
            renderer.scale = 1
            guard let cgImage = renderer.cgImage else {
                fatalError("render failed at \(px)px")
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = NSSize(width: px, height: px)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                fatalError("png encode failed at \(px)px")
            }
            rendered[px] = data
        }
        try! rendered[px]!.write(to: outputDir.appendingPathComponent(name))
        print("wrote \(name) (\(Int(px))px, \(rendered[px]!.count) bytes)")
    }
}

MainActor.assumeIsolated {
    renderAll()
}
