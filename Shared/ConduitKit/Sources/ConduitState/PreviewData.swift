//
//  PreviewData.swift
//  ConduitState
//
//  Sample state for Xcode Previews and the debug snapshot renderer. Debug
//  builds only: release builds cannot construct a store that no owner
//  controls.
//

#if DEBUG
import ConduitProtocol
import Foundation

extension ConduitStore {

    public enum PreviewScenario: String, CaseIterable, Sendable {
        /// A phone on USB and Wi-Fi, with some history.
        case connected
        /// A phone remembered from before, not attached.
        case disconnected
        /// Nothing attached and nothing remembered.
        case empty
    }

    public static func preview(_ scenario: PreviewScenario = .connected) -> ConduitStore {
        let store = ConduitStore()
        store.tools.adb = .available(path: "/opt/homebrew/bin/adb")

        let osVersion = "16"
        switch scenario {
        case .connected:
            store.phones = [
                PhoneDevice(id: "PREVIEW-S24", name: "Galaxy S24 Ultra", model: "SM-S928B", manufacturer: "samsung",
                            osVersion: osVersion, connection: .connected(.usb), transports: [.usb, .wifi],
                            features: previewFeatures(connected: true), lastSeen: Date(), isPreferred: true),
            ]
            store.activePhoneID = "PREVIEW-S24"
            store.activity = [
                ActivityEvent(kind: .clipboardSynced, title: "Clipboard synced from phone",
                              date: Date().addingTimeInterval(-60)),
                ActivityEvent(kind: .mirroringStarted, title: "Mirroring started", detail: "Over USB",
                              date: Date().addingTimeInterval(-300)),
                ActivityEvent(kind: .phoneConnected, title: "Galaxy S24 Ultra connected", detail: "Over USB",
                              date: Date().addingTimeInterval(-320)),
            ]
        case .disconnected:
            store.phones = [
                PhoneDevice(id: "PREVIEW-S24", name: "Galaxy S24 Ultra", model: "SM-S928B", manufacturer: "samsung",
                            osVersion: osVersion, connection: .disconnected,
                            features: previewFeatures(connected: false),
                            lastSeen: Date().addingTimeInterval(-7200), isPreferred: true),
            ]
            store.activePhoneID = "PREVIEW-S24"
        case .empty:
            break
        }
        return store
    }

    private static func previewFeatures(connected: Bool) -> [FeatureID: Availability] {
        let overADB: Availability = connected ? .available : .requiresSetup
        return [.mirroring: overADB, .remoteInput: overADB, .clipboard: overADB, .audio: overADB,
                .camera: .planned, .trackpad: .planned, .calls: .planned, .links: .planned,
                .files: .planned, .notifications: .planned, .findMac: .planned]
    }
}
#endif
