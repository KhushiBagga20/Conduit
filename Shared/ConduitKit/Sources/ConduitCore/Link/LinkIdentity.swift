//
//  LinkIdentity.swift
//  ConduitCore
//
//  This Mac's long-term identity for Conduit Link, and the phones it trusts.
//
//  The private key never leaves the Keychain, and the only thing stored for a
//  paired phone is what the spec lists: device ID, public key, name, platform
//  and when it was last seen.
//

import ConduitMedia
import ConduitProtocol
import CryptoKit
import Foundation

// MARK: - Identity

nonisolated protocol LinkKeyStore: Sendable {
    func loadKey() -> Data?
    func saveKey(_ key: Data) -> Bool
}

nonisolated struct LinkIdentity: Sendable {

    let signingKey: P256.Signing.PrivateKey

    var publicKey: Data { signingKey.publicKey.x963Representation }
    var deviceID: String { LinkCrypto.deviceID(forPublicKey: publicKey) }

    /// Load this Mac's identity, creating one the first time.
    static func loadOrCreate(store: LinkKeyStore = KeychainKeyStore()) -> LinkIdentity {
        if let stored = store.loadKey(), let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
            return LinkIdentity(signingKey: key)
        }
        let key = P256.Signing.PrivateKey()
        if !store.saveKey(key.rawRepresentation) {
            CoreLog.engine.error("could not store the Conduit Link identity key; pairing will not be remembered")
        }
        return LinkIdentity(signingKey: key)
    }

    /// How this Mac introduces itself.
    func deviceInfo(name: String, appVersion: String?) -> DeviceInfo {
        DeviceInfo(id: deviceID, name: name, model: Self.hardwareModel(), manufacturer: "Apple",
                   platform: .macos, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                   appVersion: appVersion)
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}

/// The login keychain. Conduit is not sandboxed, so this needs no entitlement.
nonisolated struct KeychainKeyStore: LinkKeyStore {

    private let service = "com.khushi.Conduit.link-identity"
    private let account = "mac"

    func loadKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func saveKey(_ key: Data) -> Bool {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: key,
        ]
        SecItemDelete(item as CFDictionary)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Trusted phones

nonisolated struct LinkPeer: Codable, Sendable, Equatable {
    let id: String
    var name: String
    var platform: Platform
    /// X9.63 uncompressed point.
    var publicKey: Data
    var lastSeen: Date
}

/// The phones this Mac has paired with.
final class LinkTrust {

    private static let storageKey = "linkPeers.v1"
    private let defaults: UserDefaults
    private(set) var peers: [String: LinkPeer]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([LinkPeer].self, from: data) {
            peers = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        } else {
            peers = [:]
        }
    }

    func peer(id: String) -> LinkPeer? { peers[id] }

    /// Whether this key is the one already trusted for that device ID: a
    /// device ID is derived from the key, but checking both makes a mix-up
    /// impossible to miss.
    func trusts(id: String, publicKey: Data) -> Bool {
        guard let peer = peers[id] else { return false }
        return peer.publicKey == publicKey
    }

    func remember(_ peer: LinkPeer) {
        peers[peer.id] = peer
        save()
    }

    func seen(id: String, at date: Date = Date()) {
        guard var peer = peers[id] else { return }
        peer.lastSeen = date
        peers[id] = peer
        save()
    }

    func forget(id: String) {
        peers[id] = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(peers.values)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
