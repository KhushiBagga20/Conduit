//
//  WifiReachabilityText.swift
//  Conduit
//
//  How the interfaces describe a phone's life without the cable: whether
//  unplugging keeps it working, and if not, the one thing to do about it.
//

import ConduitDesign
import ConduitState
import Foundation

extension WifiReachability {

    var tone: StatusTone {
        switch self {
        case .connected: .connected
        case .trying, .debuggingOff, .waitingForApproval: .working
        case .unknown: .idle
        case .notOnWiFi, .differentNetwork, .unreachable: .error
        }
    }

    var shortText: String {
        switch self {
        case .unknown: "Not checked yet"
        case .connected: "Connected over Wi-Fi"
        case .notOnWiFi: "The phone isn't on Wi-Fi"
        case .debuggingOff: "Wireless debugging is off"
        case .waitingForApproval: "Waiting for the phone to allow this network"
        case .differentNetwork: "On different networks"
        case .trying: "Connecting over Wi-Fi…"
        case .unreachable: "Can't reach the phone"
        }
    }

    func detail(keepsConnected: Bool) -> String? {
        switch self {
        case .unknown:
            "Plug the phone in once, and Conduit gets it ready to work without the cable."
        case .connected:
            "Unplugging keeps mirroring, files and the clipboard working."
        case .notOnWiFi:
            "Join the phone to the same Wi-Fi as this Mac, or use its hotspot, below."
        case .debuggingOff:
            keepsConnected
                ? "Conduit turns it on the next time the phone is plugged in."
                : "Turn on Keep phones connected without the cable in Settings, or turn it on in the phone's Developer options."
        case .waitingForApproval:
            "Wireless debugging is on but won't start until this Wi-Fi network is allowed. On the phone, choose Always allow on this network — Conduit puts the question up when the phone is plugged in."
        case .differentNetwork(let phone, let mac):
            "The phone is at \(phone) and this Mac at \(mac). Put them on the same Wi-Fi, or use the phone's hotspot, below."
        case .trying:
            nil
        case .unreachable:
            "They seem to share a network, but nothing gets through — offices, campuses and hotels often keep devices apart. Use the phone's hotspot, below."
        }
    }
}
