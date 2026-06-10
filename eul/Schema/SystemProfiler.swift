//
//  SystemProfiler.swift
//  eul
//
//  Created by Gao Sun on 2021/1/24.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

struct SystemProfilerPlist: Codable {
    var items: [DisplayDevice]

    enum CodingKeys: String, CodingKey {
        case items = "_items"
    }
}

typealias SystemProfilerPlistArray = [SystemProfilerPlist]

struct DisplayDevice: Codable {
    var deviceId: String?
    var deviceType: String?
    var model: String?
    var vendor: String?
    var cores: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "spdisplays_device-id"
        case deviceType = "sppci_device_type"
        case model = "sppci_model"
        case vendor = "spdisplays_vendor"
        case cores = "sppci_cores"
    }

    var isGPU: Bool {
        deviceType == "spdisplays_gpu"
    }

    /// Apple Silicon GPUs have no PCI device ID; derive a stable one from the model name
    var resolvedDeviceId: String? {
        if let deviceId = deviceId {
            return deviceId
        }
        if let model = model {
            return "apple-silicon-\(model.replacingOccurrences(of: " ", with: "-").lowercased())"
        }
        return nil
    }
}
