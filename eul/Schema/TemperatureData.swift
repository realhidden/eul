//
//  TemperatureData.swift
//  eul
//
//  Created by Gao Sun on 2020/12/1.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary

class TemperatureData {
    let sensor: TemperatureSensor
    var temp: Double
    var consecutiveFailedReads = 0
    var hasEverRead = false

    init(sensor: TemperatureSensor, temp: Double = 0) {
        self.sensor = sensor
        self.temp = temp
    }
}
