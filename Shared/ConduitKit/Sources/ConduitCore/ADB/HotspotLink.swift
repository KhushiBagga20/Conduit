//
//  HotspotLink.swift
//  ConduitCore
//
//  Reaching a phone over its own hotspot, where Wireless debugging cannot go.
//
//  Android ties Wireless debugging to being joined to a Wi-Fi network: AOSP's
//  AdbDebuggingManager turns it off the moment Wi-Fi is switched off or the
//  network drops, and refuses to start without one. A phone sharing its
//  connection has no Wi-Fi network of its own, so it can neither keep that
//  port open nor advertise itself over Bonjour.
//
//  adb's older TCP mode has no such tie: once armed, adbd listens on every
//  interface the phone has, including the hotspot. And when this Mac is on
//  that hotspot the phone *is* the network, so its address is simply the
//  Mac's gateway — nothing to discover.
//

import ConduitState
import Foundation
import SystemConfiguration

nonisolated enum HotspotLink {

    static let defaultPort = HotspotAccess.port

    /// The router of this Mac's primary IPv4 network — the phone itself
    /// while the Mac is on its hotspot. Nil when the Mac has no network.
    static func currentGateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Conduit" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = global["Router"] as? String,
              !router.isEmpty
        else { return nil }
        return router
    }
}
