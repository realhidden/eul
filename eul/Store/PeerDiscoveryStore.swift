//
//  PeerDiscoveryStore.swift
//  eul
//
//  Created by Zsombor Paróczi on 2026/9/25.
//  Copyright © 2026 Zsombor Paróczi. All rights reserved.
//

import Combine
import CryptoKit
import Foundation
import Network

/// Finds other Macs running eul with the same shared secret on the local
/// network. Each instance advertises `_eul-peer._tcp` over Bonjour with a
/// token derived from the secret in its TXT record (never the secret
/// itself), and lists the services advertising the same token.
class PeerDiscoveryStore: ObservableObject {
    struct Peer: Identifiable, Equatable {
        let name: String

        var id: String {
            name
        }
    }

    @Published private(set) var peers: [Peer] = []

    private static let serviceType = "_eul-peer._tcp"
    private static let tokenKey = "t"

    private var listener: NWListener?
    private var browser: NWBrowser?
    /// our own registered service name, so we never list ourselves
    private var ownName: String?
    /// names advertising our token, as of the last browse result
    private var matches: Set<String> = []
    private var cancellable: AnyCancellable?

    init() {
        // the settings field changes the secret per keystroke — settle
        // before tearing down and re-registering the service
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

    /// truncated HMAC of the secret: peers can match tokens without the
    /// secret going out on the wire
    private static func token(for secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(serviceType.utf8), using: key)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func restart(secret: String) {
        stop()
        guard !secret.isEmpty else {
            return
        }

        let token = Self.token(for: secret)
        advertise(token: token)
        browse(token: token)
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        ownName = nil
        matches = []
        publishPeers()
    }

    private func advertise(token: String) {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp)
        } catch {
            print("🔍 unable to create peer listener", error)
            return
        }

        var txt = NWTXTRecord()
        txt[Self.tokenKey] = token
        listener.service = NWListener.Service(type: Self.serviceType, txtRecord: txt)
        // discovery only — nothing is served over the connection yet
        listener.newConnectionHandler = { $0.cancel() }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            // the registered name can differ from the host name after a conflict
            if case let .add(.service(name, _, _, _)) = change {
                self?.ownName = name
                self?.publishPeers()
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

    private func browse(token: String) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // one result per interface — collapse to names
            self?.matches = Set(results.compactMap { result in
                guard
                    case let .service(name, _, _, _) = result.endpoint,
                    case let .bonjour(txt) = result.metadata,
                    txt[Self.tokenKey] == token
                else {
                    return nil
                }
                return name
            })
            self?.publishPeers()
        }
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("🔍 peer browser failed", error)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func publishPeers() {
        let next = matches.filter { $0 != ownName }.sorted().map(Peer.init)
        if next != peers {
            peers = next
        }
    }
}
