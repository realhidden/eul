//
//  MQTTClient.swift
//  eul
//
//  Created by Zsombor Paróczi on 2026/9/25.
//  Copyright © 2026 Zsombor Paróczi. All rights reserved.
//

import Foundation
import Network

/// Minimal MQTT 3.1.1 client — QoS 0 publish/subscribe to a single topic
/// over TLS, just enough to use a public broker as a relay. Keeps itself
/// connected: on failure it moves to the next broker and resubscribes.
final class MQTTClient {
    struct Broker {
        let host: String
        let port: UInt16
    }

    var onMessage: ((Data) -> Void)?

    private let brokers: [Broker]
    private let topic: String
    private let clientID = "eul-\(UUID().uuidString.prefix(8))"
    private let keepAlive: UInt16 = 60
    private var brokerIndex = 0
    private var connection: NWConnection?
    private var buffer = Data()
    private var isConnected = false
    private var lastReceived = Date()
    private var pingTimer: Timer?
    private var isStopped = false

    init(brokers: [Broker], topic: String) {
        self.brokers = brokers
        self.topic = topic
    }

    deinit {
        stop()
    }

    func start() {
        isStopped = false
        connect()
    }

    func stop() {
        isStopped = true
        if isConnected {
            send(Data([0xE0, 0x00])) // DISCONNECT
        }
        teardown()
    }

    func publish(_ payload: Data) {
        guard isConnected else {
            return
        }
        send(Self.packet(0x30, Self.string(topic) + payload))
    }

    // MARK: connection

    private func connect() {
        let broker = brokers[brokerIndex % brokers.count]
        let connection = NWConnection(host: .init(broker.host), port: .init(integerLiteral: broker.port), using: .tls)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, connection === self.connection else {
                return
            }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.send(self.connectPacket())
                self.receive()
            case let .failed(error), let .waiting(error):
                print("📡 relay \(broker.host) unavailable", error)
                self.reconnect()
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: .main)
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        buffer = Data()
        isConnected = false
    }

    private func reconnect() {
        teardown()
        guard !isStopped else {
            return
        }
        brokerIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, !self.isStopped, self.connection == nil else {
                return
            }
            self.connect()
        }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        let connection = self.connection
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            // a torn-down connection still delivers its final error
            guard let self = self, let connection = connection, connection === self.connection else {
                return
            }
            if let data = data, !data.isEmpty {
                self.lastReceived = Date()
                self.buffer.append(data)
                self.drainPackets()
            }
            if isComplete || error != nil {
                self.reconnect()
            } else {
                self.receive()
            }
        }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(keepAlive / 2), repeats: true) { [weak self] _ in
            guard let self = self else {
                return
            }
            // no PINGRESP (or anything) for two intervals — the link is dead
            // even if the socket has not noticed yet
            if -self.lastReceived.timeIntervalSinceNow > TimeInterval(self.keepAlive) {
                self.reconnect()
                return
            }
            self.send(Data([0xC0, 0x00])) // PINGREQ
        }
    }

    // MARK: packets

    private func connectPacket() -> Data {
        var body = Self.string("MQTT")
        body.append(4) // protocol level 3.1.1
        body.append(0x02) // clean session
        body.append(contentsOf: [UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)])
        body.append(Self.string(clientID))
        return Self.packet(0x10, body)
    }

    private func drainPackets() {
        while let (header, body, length) = Self.nextPacket(in: buffer) {
            buffer.removeFirst(length)
            handle(header: header, body: body)
        }
    }

    private func handle(header: UInt8, body: Data) {
        switch header & 0xF0 {
        case 0x20: // CONNACK
            guard body.count >= 2, body[body.startIndex + 1] == 0 else {
                print("📡 relay refused connection")
                reconnect()
                return
            }
            isConnected = true
            // SUBSCRIBE, packet id 1, QoS 0
            send(Self.packet(0x82, Data([0x00, 0x01]) + Self.string(topic) + Data([0x00])))
            startPinging()
        case 0x30: // PUBLISH
            guard body.count >= 2 else {
                return
            }
            let topicLength = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
            var offset = 2 + topicLength
            // QoS > 0 carries a packet id; we subscribe at QoS 0 so it should not
            if (header >> 1) & 0x03 > 0 {
                offset += 2
            }
            guard body.count >= offset else {
                return
            }
            onMessage?(body.dropFirst(offset))
        default: // SUBACK, PINGRESP
            break
        }
    }

    private static func packet(_ header: UInt8, _ body: Data) -> Data {
        var data = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while length > 0
        return data + body
    }

    private static func string(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        return Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]) + utf8
    }

    /// (fixed header byte, body, total packet length) of the first complete
    /// packet in `buffer`, or nil until more bytes arrive
    private static func nextPacket(in buffer: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](buffer.prefix(5))
        guard bytes.count >= 2 else {
            return nil
        }
        var length = 0
        var multiplier = 1
        var index = 1
        while true {
            guard index < bytes.count else {
                return nil
            }
            let byte = bytes[index]
            length += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 {
                break
            }
            multiplier *= 128
        }
        guard buffer.count >= index + length else {
            return nil
        }
        let start = buffer.startIndex
        return (bytes[0], Data(buffer[(start + index)..<(start + index + length)]), index + length)
    }
}
