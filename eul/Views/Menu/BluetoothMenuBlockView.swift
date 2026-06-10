//
//  BluetoothMenuBlockView.swift
//  eul
//
//  Created by Gao Sun on 2021/1/18.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import SwiftUI

struct BluetoothRowView: View {
    let device: BluetoothDevice
    var nameWidth: CGFloat = 200

    var body: some View {
        HStack {
            Text(device.displayName)
                .secondaryDisplayText()
                .frame(width: nameWidth, alignment: .leading)
                .lineLimit(1)
            Spacer()
            if device.hasBattery {
                if let percent = device.batteryPercent {
                    MenuInfoView(text: "\(percent)%")
                }
                if let percent = device.batteryPercentLeft {
                    MenuInfoView(label: "L", text: "\(percent)%")
                }
                if let percent = device.batteryPercentRight {
                    MenuInfoView(label: "R", text: "\(percent)%")
                }
                if let percent = device.batteryPercentCase {
                    MenuInfoView(label: "C", text: "\(percent)%")
                }
            }
        }
    }
}

struct BluetoothMenuBlockView: View {
    @EnvironmentObject var bluetoothStore: BluetoothStore

    var body: some View {
        VStack(spacing: 8) {
            Text("bluetooth".localized())
                .menuSection()
            if bluetoothStore.devices.count == 0 {
                Text("ui.empty".localized())
                    .placeholder()
                    .padding(.bottom, 4)
            }
            ForEach(bluetoothStore.devices) {
                BluetoothRowView(device: $0)
            }
        }
        .padding(.top, 2)
        .menuBlock()
        .onAppear {
            bluetoothStore.fetch()
        }
    }
}
