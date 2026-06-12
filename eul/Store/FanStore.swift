//
//  FanStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/29.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation

class FanStore: ObservableObject, Refreshable {
    @Published var fans: [FanData] = []

    @objc func refresh() {
        // fanless Macs: both arrays stay empty forever — skip the publish
        if fans.isEmpty, SmcControl.shared.fans.isEmpty {
            return
        }
        fans = SmcControl.shared.fans
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
    }
}
