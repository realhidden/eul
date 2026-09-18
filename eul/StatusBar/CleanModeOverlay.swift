//
//  CleanModeOverlay.swift
//  eul
//
//  Created for Clean Mode (hardware wipe).
//

import AppKit
import SwiftUI

/// Full-screen host for Clean Mode. A borderless, key-capable black window per
/// screen at screen-saver level — it covers the menu bar and every app and
/// takes keyboard focus from whatever was frontmost, while (crucially) leaving
/// the mouse working so the hold-to-exit gesture can drive the way out. There
/// is deliberately no `cancelOperation` / Esc handler: keys do nothing here.
final class CleanModeOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
    }
}

/// Owns the overlay windows (one per screen) and their lifecycle. The screen
/// with the menu bar hosts the interactive card/ring; the rest just black out
/// but still accept the hold gesture, so "hold anywhere" means any display.
/// Rebuilds on a display hot-plug so a newly attached screen can't stay lit.
final class CleanModeOverlayController {
    private var windows: [CleanModeOverlayWindow] = []
    private weak var manager: CleanModeManager?
    private var screenObserver: NSObjectProtocol?

    func show(manager: CleanModeManager) {
        self.manager = manager
        build()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // tearing down windows mid-hold would strip the gesture before its
            // onEnded fires; reset the hold so the rebuilt windows start clean
            self?.manager?.cancelHold()
            self?.build()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
    }

    private func build() {
        guard let manager = manager else {
            return
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows = []

        let screens = NSScreen.screens
        let primaryIndex = screens.firstIndex { $0 == NSScreen.main } ?? 0
        var primaryWindow: CleanModeOverlayWindow?

        for (index, screen) in screens.enumerated() {
            let window = CleanModeOverlayWindow(frame: screen.frame)
            let root = CleanModeOverlayView(manager: manager, isPrimary: index == primaryIndex)
            window.contentView = NSHostingView(rootView: root)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            if index == primaryIndex {
                primaryWindow = window
            }
        }
        // only one window can be key; the interactive one must own it
        primaryWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The SwiftUI canvas. Always dark-scheme. Black through `confirming` and
/// `active`, fades out on `exiting`. The interactive card/ring render only on
/// the primary screen; the hold-gesture layer runs on every screen.
struct CleanModeOverlayView: View {
    @ObservedObject var manager: CleanModeManager
    let isPrimary: Bool

    private var secondary: Color {
        Color.white.opacity(0.6)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(manager.phase == .exiting ? 0 : 1)
                .animation(.easeInOut(duration: 0.35), value: manager.phase)

            if isPrimary {
                content
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: manager.phase)
                    .animation(.easeInOut(duration: 0.25), value: manager.reminderVisible)
            }

            // hold-to-exit lives above the visuals so a press anywhere counts;
            // only attached once the screen is fully dark and waiting
            if manager.acceptsHold {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in manager.beginHold() }
                            .onEnded { _ in manager.cancelHold() }
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgesIgnoringSafeArea(.all)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch manager.phase {
        case .confirming:
            confirmCard
        case .active:
            activeContent
        default:
            EmptyView()
        }
    }

    // MARK: - confirm (the restoration guide)

    private func guideRow(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 16)
            Text(key.localized())
                .font(.system(size: 12))
                .foregroundColor(secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func filledButton(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key.localized())
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.black)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white)
        .cornerRadius(8)
        .pointingHandCursor()
    }

    private func quietButton(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key.localized())
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.white)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.12))
        .cornerRadius(8)
        .pointingHandCursor()
    }

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("clean_mode.title".localized())
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text("clean_mode.subtitle".localized())
                    .font(.system(size: 12.5))
                    .foregroundColor(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if manager.needsPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("clean_mode.permission.heading".localized())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignTokens.Health.elevated)
                    Text("clean_mode.permission.body".localized())
                        .font(.system(size: 12))
                        .foregroundColor(secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("clean_mode.guide.heading".localized())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(secondary)
                    guideRow("↧", "clean_mode.guide.hold")
                    guideRow("✦", "clean_mode.guide.restore")
                    guideRow("⏲", "clean_mode.guide.auto")
                }
            }

            HStack(spacing: 10) {
                quietButton("clean_mode.cancel") {
                    manager.cancel()
                }
                Spacer(minLength: 12)
                if manager.needsPermission {
                    filledButton("clean_mode.open_settings") {
                        manager.openPermissionSettings()
                    }
                } else {
                    filledButton("clean_mode.start") {
                        manager.start()
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    // MARK: - active (reminder · dark · hold ring)

    @ViewBuilder
    private var activeContent: some View {
        if manager.reminderVisible {
            Text("clean_mode.reminder".localized())
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        } else if manager.holdProgress > 0 {
            holdRing
        }
        // otherwise: fully dark, nothing drawn — the screen is ready to wipe
    }

    private var holdRing: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(manager.holdProgress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 78, height: 78)

            Text("clean_mode.releasing".localized())
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            Text(String(format: "clean_mode.auto_exit".localized(), timeString(manager.secondsRemaining)))
                .font(.system(size: 11))
                .foregroundColor(secondary)
        }
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
