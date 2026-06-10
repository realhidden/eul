//
//  SmcControl.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Foundation
import SharedLibrary
import SwiftyJSON

class SmcControl: Refreshable {
    static var shared = SmcControl()

    var sensors: [TemperatureData] = []
    var fans: [FanData] = []
    var tempUnit: TemperatureUnit = .celius
    /// SMC die/proximity keys exist on Intel only; on Apple Silicon the same
    /// readings come from IOHID PMU sensors (AppleSiliconSensors.shared is nil
    /// on Intel, so each getter falls through to nil there as before).
    var cpuDieTemperature: Double? {
        if let temp = sensors.first(where: { $0.sensor.name == "CPU_0_DIE" })?.temp, temp > 0 {
            return temp
        }
        return AppleSiliconSensors.shared?.cpuTemperature
    }

    var cpuProximityTemperature: Double? {
        if let temp = sensors.first(where: { $0.sensor.name == "CPU_0_PROXIMITY" })?.temp, temp > 0 {
            return temp
        }
        return AppleSiliconSensors.shared?.cpuTemperature
    }

    var gpuProximityTemperature: Double? {
        if let temp = sensors.first(where: { $0.sensor.name == "GPU_0_PROXIMITY" })?.temp, temp > 0 {
            return temp
        }
        return AppleSiliconSensors.shared?.gpuTemperature
    }

    var memoryProximityTemperature: Double? {
        if let temp = sensors.first(where: { $0.sensor.name == "MEM_SLOTS_PROXIMITY" })?.temp, temp > 0 {
            return temp
        }
        return AppleSiliconSensors.shared?.socTemperature
    }

    var isFanValid: Bool {
        fans.count > 0
    }

    func formatTemp(_ value: Double) -> String {
        String(format: "%.0f°\(tempUnit == .celius ? "C" : "F")", value)
    }

    init() {
        #if arch(arm64)
            AppleSiliconSensors.initialize()
        #endif
        // Keep the SMC path on both architectures: Apple Silicon has no
        // CPU/GPU temperature keys but still exposes fans through SMC.
        do {
            try SMCKit.open()
            sensors = try SMCKit.allKnownTemperatureSensors().map { .init(sensor: $0) }
            fans = try (0..<SMCKit.fanCount()).map { FanData(
                id: $0,
                minSpeed: try? SMCKit.fanMinSpeed($0),
                maxSpeed: try? SMCKit.fanMaxSpeed($0)
            ) }
        } catch {
            print("SMC init error", error)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func subscribe() {
        initObserver(for: .SMCShouldRefresh)
    }

    func close() {
        SMCKit.close()
    }

    @objc func refresh() {
        for sensor in sensors {
            do {
                sensor.temp = try SMCKit.temperature(sensor.sensor.code, unit: tempUnit)
            } catch {
                sensor.temp = 0
                print("error while getting temperature", error)
            }
        }
        fans = fans.map {
            FanData(
                id: $0.id,
                currentSpeed: try? SMCKit.fanCurrentSpeed($0.id),
                minSpeed: $0.minSpeed,
                maxSpeed: $0.maxSpeed
            )
        }
        NotificationCenter.default.post(name: .StoreShouldRefresh, object: nil)
    }
}

extension TemperatureUnit {
    var description: String {
        switch self {
        case .celius:
            return "temp.celsius".localized()
        case .fahrenheit:
            return "temp.fahrenheit".localized()
        case .kelvin:
            return "temp.kelvin".localized()
        }
    }
}

extension Fan: JSONCodabble {
    init?(json: JSON) {
        guard
            let id = json["id"].int,
            let name = json["name"].string,
            let minSpeed = json["id"].int,
            let maxSpeed = json["id"].int
        else {
            return nil
        }
        self.id = id
        self.name = name
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
    }

    var json: JSON {
        JSON([
            "id": id,
            "name": name,
            "minSpeed": minSpeed,
            "maxSpeed": maxSpeed,
        ])
    }
}

extension Double {
    var temperatureString: String {
        SmcControl.shared.formatTemp(self)
    }
}
