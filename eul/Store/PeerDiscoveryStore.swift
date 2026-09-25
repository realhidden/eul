//
//  PeerDiscoveryStore.swift
//  eul
//
//  Created by Zsombor Paróczi on 2026/9/25.
//  Copyright © 2026 Zsombor Paróczi. All rights reserved.
//

import Combine
import CommonCrypto
import CryptoKit
import Foundation
import Network
import SharedLibrary

/// Macs running eul with the same shared secret find each other and share a
/// small stats snapshot every few seconds, over two transports at once:
/// - LAN: Bonjour `_eul-peer._udp`, snapshots sent straight to each peer
/// - internet: a public MQTT broker, on a topic derived from the secret
///
/// Every snapshot is sealed (ChaChaPoly) with a key derived from the secret,
/// so neither the network nor the broker sees the secret or the stats.
class PeerDiscoveryStore: ObservableObject {
    enum Transport {
        case lan
        case relay
    }

    struct Stats: Codable, Equatable {
        var cpu: Double?
        var memory: Double?
        var gpu: Double?
        /// in the sender's unit, as its own UI shows it
        var temperature: Double?
        var temperatureUnit: TemperatureUnit
        var networkIn: Double
        var networkOut: Double

        func temperature(in unit: TemperatureUnit) -> Double? {
            guard let value = temperature else {
                return nil
            }
            let celsius: Double
            switch temperatureUnit {
            case .celius: celsius = value
            case .fahrenheit: celsius = (value - 32) / 1.8
            case .kelvin: celsius = value - 273.15
            }
            switch unit {
            case .celius: return celsius
            case .fahrenheit: return TemperatureUnit.toFahrenheit(celsius)
            case .kelvin: return TemperatureUnit.toKelvin(celsius)
            }
        }
    }

    struct Peer: Identifiable, Equatable {
        let id: String
        var name: String
        var stats: Stats
        var via: Set<Transport>
        var lastSeen: Date
    }

    @Published private(set) var peers: [Peer] = []

    /// what goes on the wire, sealed with the secret-derived key
    private struct Snapshot: Codable {
        let id: String
        let name: String
        let sentAt: Date
        let stats: Stats
    }

    private struct Keys {
        let lanToken: String
        let topic: String
        let seal: SymmetricKey
    }

    private static let serviceType = "_eul-peer._udp"
    private static let tokenKey = "t"
    private static let interval: TimeInterval = 5
    /// three missed snapshots and the peer is gone
    private static let expiry: TimeInterval = 16
    /// replayed snapshots older than this are dropped
    private static let maxAge: TimeInterval = 60
    /// free, open brokers — tried in order, moving on when one fails
    private static let brokers = [
        MQTTClient.Broker(host: "broker.emqx.io", port: 8883),
        MQTTClient.Broker(host: "broker.hivemq.com", port: 8883),
        MQTTClient.Broker(host: "test.mosquitto.org", port: 8886),
    ]

    /// per launch: a restarted peer simply shows up as new and the old
    /// entry expires
    private let instanceID = UUID().uuidString
    private let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    private var keys: Keys?
    private var timer: Timer?
    private var table: [String: Peer] = [:]
    private var cancellable: AnyCancellable?

    private var listener: NWListener?
    private var browser: NWBrowser?
    /// our own registered service name, so we never send to ourselves
    private var ownName: String?
    /// flows to LAN peers, by service name
    private var outbound: [String: NWConnection] = [:]
    /// flows from LAN peers, as the listener accepts them
    private var inbound: [ObjectIdentifier: NWConnection] = [:]
    private var relay: MQTTClient?

    init() {
        // the settings field changes the secret per keystroke — settle
        // before tearing down and re-registering everything
        cancellable = SharedStore.preference.$sharedSecret
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.restart(secret: $0)
            }
    }

    deinit {
        stop()
    }

    // MARK: lifecycle

    private func restart(secret: String) {
        stop()
        guard !secret.isEmpty else {
            return
        }

        let keys = Self.deriveKeys(from: secret)
        self.keys = keys
        advertise(token: keys.lanToken)
        browse(token: keys.lanToken)

        let relay = MQTTClient(brokers: Self.brokers, topic: keys.topic)
        relay.onMessage = { [weak self] in
            self?.receive($0, via: .relay)
        }
        relay.start()
        self.relay = relay

        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        relay?.stop()
        relay = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        outbound.values.forEach { $0.cancel() }
        outbound = [:]
        inbound.values.forEach { $0.cancel() }
        inbound = [:]
        ownName = nil
        keys = nil
        table = [:]
        publishPeers()
    }

    private func tick() {
        table = table.filter { -$0.value.lastSeen.timeIntervalSinceNow < Self.expiry }
        publishPeers()

        guard let payload = sealedSnapshot() else {
            return
        }
        for value in outbound.values {
            value.send(content: payload, completion: .idempotent)
        }
        relay?.publish(payload)
    }

    // MARK: snapshots

    /// PBKDF2 stretches a typed secret (the topic is visible to anyone on the
    /// broker), HKDF splits it into independent tokens and the sealing key
    private static func deriveKeys(from secret: String) -> Keys {
        let salt = Array("eul-peer".utf8)
        var master = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            secret, secret.utf8.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
            &master, master.count
        )
        let ikm = SymmetricKey(data: master)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data(label.utf8), outputByteCount: 32)
        }
        func hex(_ key: SymmetricKey) -> String {
            key.withUnsafeBytes { $0.prefix(16).map { String(format: "%02x", $0) }.joined() }
        }
        return Keys(lanToken: hex(derive("lan")), topic: "eul-peer/\(hex(derive("topic")))", seal: derive("seal"))
    }

    private func currentStats() -> Stats {
        let memory = SharedStore.memory
        return Stats(
            cpu: SharedStore.cpu.usage,
            memory: memory.total > 0 ? memory.usedPercentage : nil,
            gpu: SharedStore.gpu.usageAverage,
            temperature: SharedStore.cpu.temp,
            temperatureUnit: SmcControl.shared.tempUnit,
            networkIn: SharedStore.network.inSpeedInByte,
            networkOut: SharedStore.network.outSpeedInByte
        )
    }

    private func sealedSnapshot() -> Data? {
        guard let keys = keys else {
            return nil
        }
        let snapshot = Snapshot(id: instanceID, name: name, sentAt: Date(), stats: currentStats())
        guard let json = try? JSONEncoder().encode(snapshot) else {
            return nil
        }
        return try? ChaChaPoly.seal(json, using: keys.seal).combined
    }

    private func receive(_ data: Data, via transport: Transport) {
        guard
            let keys = keys,
            let box = try? ChaChaPoly.SealedBox(combined: data),
            let json = try? ChaChaPoly.open(box, using: keys.seal),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: json),
            // the broker echoes our own publishes back
            snapshot.id != instanceID,
            abs(snapshot.sentAt.timeIntervalSinceNow) < Self.maxAge
        else {
            return
        }

        var peer = table[snapshot.id] ?? Peer(id: snapshot.id, name: snapshot.name, stats: snapshot.stats, via: [], lastSeen: Date())
        peer.name = snapshot.name
        peer.stats = snapshot.stats
        peer.via.insert(transport)
        peer.lastSeen = Date()
        table[snapshot.id] = peer
        publishPeers()
    }

    private func publishPeers() {
        let next = table.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if next != peers {
            peers = next
        }
    }

    // MARK: LAN transport

    private func advertise(token: String) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .udp)
        } catch {
            print("🔍 unable to create peer listener", error)
            return
        }

        var txt = NWTXTRecord()
        txt[Self.tokenKey] = token
        listener.service = NWListener.Service(type: Self.serviceType, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            // the registered name can differ from the host name after a conflict
            if case let .add(.service(name, _, _, _)) = change {
                self?.ownName = name
                self?.outbound.removeValue(forKey: name)?.cancel()
            }
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("🔍 peer listener failed", error)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        inbound[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.inbound.removeValue(forKey: key)
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveDatagrams(on: connection)
    }

    private func receiveDatagrams(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            if let data = data {
                self?.receive(data, via: .lan)
            }
            if error == nil, let connection = connection {
                self?.receiveDatagrams(on: connection)
            }
        }
    }

    private func browse(token: String) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .udp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.updateOutbound(results: results, token: token)
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("🔍 peer browser failed", error)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// one flow per matching service; results repeat per interface, the
    /// first endpoint of each name wins
    private func updateOutbound(results: Set<NWBrowser.Result>, token: String) {
        var endpoints: [String: NWEndpoint] = [:]
        for result in results {
            guard
                case let .service(name, _, _, _) = result.endpoint,
                name != ownName,
                case let .bonjour(txt) = result.metadata,
                txt[Self.tokenKey] == token
            else {
                continue
            }
            endpoints[name] = endpoints[name] ?? result.endpoint
        }

        for name in outbound.keys where endpoints[name] == nil {
            outbound.removeValue(forKey: name)?.cancel()
        }
        for (name, endpoint) in endpoints where outbound[name] == nil {
            let connection = NWConnection(to: endpoint, using: .udp)
            connection.start(queue: .main)
            outbound[name] = connection
        }
    }
}
