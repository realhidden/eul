//
//  PreferenceStore.swift
//  eul
//
//  Created by Gao Sun on 2020/8/15.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Cocoa
import Combine
import Foundation
import Localize_Swift
import SharedLibrary
import SwiftyJSON
import WidgetKit

/// identity of a panel tile for hide/restore (design §4.7): hiding is
/// point-of-use (right-click the tile), restoring lives in Settings · General
enum PanelTileKind: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case network
    case gpu
    case disk
    case fans
    case battery
    case bluetooth

    var id: String {
        rawValue
    }

    var localizedDescription: String {
        switch self {
        case .fans:
            return "component.fan".localized()
        default:
            return "component.\(rawValue)".localized()
        }
    }
}

class PreferenceStore: ObservableObject {
    enum UpgradeMethod: String, CaseIterable {
        case none
        case showInStatusBar
        case autoUpdate
    }

    static var availableLanguages: [String] {
        Localize.availableLanguages().filter { $0 != "Base" }
    }

    private let userDefaultsKey = "preference"
    private let repo = "gao-sun/eul"
    private var cancellable: AnyCancellable?
    private var temperatureUnitCancellable: AnyCancellable?
    var repoURL: URL? {
        URL(string: "https://github.com/\(repo)")
    }

    var latestReleaseURL: URL? {
        URL(string: "https://github.com/\(repo)/releases/latest")
    }

    var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    @Published var temperatureUnit = TemperatureUnit.celius {
        willSet {
            SmcControl.shared.tempUnit = newValue
        }
    }

    /// rates speak bits or bytes (design §4.7, ask 18) — one choice, applied
    /// everywhere: bar slot, panel, process rows, Trends widget
    @Published var networkRateInBits = false

    /// drops the CPU/NET caps labels in the strip for the dense-bar minority
    /// (design §4.7) — one decision, not a layout editor
    @Published var valueOnlySlots = false

    /// panel tiles hidden via right-click (design §4.7, "battery rows are
    /// noise" story); raw PanelTileKind values
    @Published var hiddenTiles: [String] = []

    func isTileHidden(_ kind: PanelTileKind) -> Bool {
        hiddenTiles.contains(kind.rawValue)
    }

    func hideTile(_ kind: PanelTileKind) {
        guard !isTileHidden(kind) else {
            return
        }
        hiddenTiles.append(kind.rawValue)
    }

    func restoreTile(_ kind: PanelTileKind) {
        hiddenTiles.removeAll { $0 == kind.rawValue }
    }

    @Published var language = Localize.currentLanguage() {
        willSet {
            Localize.setCurrentLanguage(newValue)
        }
    }

    @Published var smcRefreshRate = 3
    @Published var networkRefreshRate = 3
    /// no longer user-facing — kept persisted because the one-time
    /// ComponentConfigStore.convertIfNeeded() migration reads it
    @Published var showIcon = true
    @Published var checkStatusItemVisibility = true
    @Published var upgradeMethod = UpgradeMethod.showInStatusBar
    @Published var isUpdateAvailable: Bool? = false
    @Published var checkUpdateFailed = true
    @Published var appearanceMode = Preference.appearance.auto

    var json: JSON {
        JSON([
            "temperatureUnit": temperatureUnit.rawValue,
            "networkRateInBits": networkRateInBits,
            "valueOnlySlots": valueOnlySlots,
            "hiddenTiles": hiddenTiles,
            "language": language,
            "smcRefreshRate": smcRefreshRate,
            "networkRefreshRate": networkRefreshRate,
            "showIcon": showIcon,
            "checkStatusItemVisibility": checkStatusItemVisibility,
            "appearance": appearanceMode.rawValue,
            "upgradeMethod": upgradeMethod.rawValue,

        ])
    }

    init() {
        loadFromDefaults()
        writeToContainer()

        cancellable = objectWillChange.sink {
            DispatchQueue.main.async {
                self.saveToDefaults()
            }
        }
        // PreferenceEntry's only field is temperatureUnit — rewrite the
        // container (and wake widgets) only when that actually changes, not on
        // every unrelated @Published mutation (e.g. the hourly checkUpdate)
        temperatureUnitCancellable = $temperatureUnit.removeDuplicates().dropFirst().sink { _ in
            DispatchQueue.main.async {
                self.writeToContainer()
            }
        }
    }

    func checkUpdate() {
        isUpdateAvailable = nil
        checkUpdateFailed = false

        let session = URLSession.shared
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")

        if let url = url {
            let task = session.dataTask(with: url) { data, _, error in
                DispatchQueue.main.async {
                    if
                        error == nil,
                        let version = self.version,
                        let tagName = JSON(data as Any)["tag_name"].string,
                        "v\(version)".compare(tagName, options: .numeric) == .orderedAscending
                    {
                        self.isUpdateAvailable = true

                        if self.upgradeMethod == .autoUpdate {
                            AutoUpdate.run()
                        }
                    } else {
                        self.isUpdateAvailable = false
                    }
                }
            }
            task.resume()
        } else {
            isUpdateAvailable = false
            checkUpdateFailed = true
        }
    }

    func loadFromDefaults() {
        if let raw = UserDefaults.standard.data(forKey: userDefaultsKey) {
            do {
                let data = try JSON(data: raw)

                print("⚙️ loaded data from user defaults", userDefaultsKey, data)

                if let raw = data["temperatureUnit"].string, let value = TemperatureUnit(rawValue: raw) {
                    temperatureUnit = value
                }
                if let value = data["networkRateInBits"].bool {
                    networkRateInBits = value
                }
                if let value = data["valueOnlySlots"].bool {
                    valueOnlySlots = value
                }
                if let array = data["hiddenTiles"].array {
                    hiddenTiles = array.compactMap { $0.string }
                }
                if let value = data["language"].string {
                    language = value
                }
                if let value = data["showIcon"].bool {
                    showIcon = value
                }
                if let value = data["smcRefreshRate"].int {
                    smcRefreshRate = value
                }
                if let value = data["networkRefreshRate"].int {
                    networkRefreshRate = value
                }
                if let value = data["checkStatusItemVisibility"].bool {
                    checkStatusItemVisibility = value
                }
                if let raw = data["appearance"].string, let value = Preference.appearance(rawValue: raw) {
                    appearanceMode = value
                }
                if let raw = data["upgradeMethod"].string, let value = UpgradeMethod(rawValue: raw) {
                    upgradeMethod = value
                }
            } catch {
                print("Unable to get preference data from user defaults")
            }
        }
    }

    func saveToDefaults() {
        do {
            let data = try json.rawData()
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("Unable to save preference")
        }
    }

    func writeToContainer() {
        Container.set(PreferenceEntry(temperatureUnit: temperatureUnit))
        WidgetReloader.requestReloadAll()
    }
}
