//
//  HotspotRequestText.swift
//  Conduit
//
//  How the interfaces describe asking the phone for its hotspot.
//

import ConduitState
import Foundation

extension HotspotRequestStatus {

    /// A word or two for the menu bar.
    var shortStatus: String? {
        switch self {
        case .idle: nil
        case .asking: "Asking…"
        case .asked: "Asked"
        case .noPhoneNearby: "Not nearby"
        case .bluetoothOff: "Bluetooth off"
        case .bluetoothDenied: "Needs Bluetooth"
        case .failed: "Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Asks your linked phone over Bluetooth. Android lets only the phone turn its hotspot on, so it shows a notification to tap."
        case .asking:
            "Looking for your phone over Bluetooth…"
        case .asked(let date):
            "Asked \(date.formatted(.relative(presentation: .named))). Tap the notification on the phone; this Mac rejoins the hotspot by itself."
        case .noPhoneNearby:
            "No linked phone answered. Keep it close, with Bluetooth on, and open Conduit for Android once to let it be asked."
        case .bluetoothOff:
            "Turn on Bluetooth on this Mac to ask the phone."
        case .bluetoothDenied:
            "Allow Conduit in System Settings → Privacy & Security → Bluetooth."
        case .failed(let message):
            message
        }
    }
}
