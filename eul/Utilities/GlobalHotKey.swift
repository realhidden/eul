//
//  GlobalHotKey.swift
//  eul
//
//  Created by Gao Sun on 2026/6/10.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import Carbon
import Foundation

/// ⌃⌥E opens the panel regardless of bar state — the always-available escape
/// hatch of the recovery flow (design §2.5). Carbon RegisterEventHotKey needs
/// no accessibility permission and remains the supported mechanism; note
/// macOS 15+ rejects Option-only modifiers, so the default includes Control.
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?

    static func register() {
        guard hotKeyRef == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    if PanelManager.shared.isOpen {
                        PanelManager.shared.close()
                    } else if StatusBarManager.shared.anchor.isOccluded {
                        PanelManager.shared.openCentered()
                    } else {
                        PanelManager.shared.open()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x6575_6C31) /* 'eul1' */, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_E),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            Print("hotkey registration failed with status", status)
        }
    }
}
