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
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ConduitStore {

    public enum PreviewScenario: String, CaseIterable, Sendable {
        /// A phone on USB and Wi-Fi, with some history.
        case connected
        /// A phone remembered from before, not attached.
        case disconnected
        /// Nothing attached and nothing remembered.
        case empty
        /// Connected, with mirroring waiting for the phone to come back.
        case waitingForPhone
        /// Plugged in, on a Wi-Fi that keeps the phone and Mac apart.
        case keptApart
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
                            features: previewFeatures(connected: true), lastSeen: Date(), isPreferred: true,
                            companionApp: .installed(canManageSettings: false)),
            ]
            store.activePhoneID = "PREVIEW-S24"
            previewFiles(in: store.files)
            store.activity = [
                ActivityEvent(kind: .clipboardSynced, title: "Clipboard synced from phone",
                              date: Date().addingTimeInterval(-60)),
                ActivityEvent(kind: .mirroringStarted, title: "Mirroring started", detail: "Over USB",
                              date: Date().addingTimeInterval(-300)),
                ActivityEvent(kind: .phoneConnected, title: "Galaxy S24 Ultra connected", detail: "Over USB",
                              date: Date().addingTimeInterval(-320)),
            ]
        case .keptApart:
            var phone = PhoneDevice(id: "PREVIEW-S24", name: "Galaxy S24 Ultra", model: "SM-S928B", manufacturer: "samsung",
                                    osVersion: osVersion, connection: .connected(.usb), transports: [.usb],
                                    features: previewFeatures(connected: true), lastSeen: Date(), isPreferred: true,
                                    companionApp: .installed(canManageSettings: false))
            phone.wifi = .keptApart
            phone.sharesWiFi = true
            store.phones = [phone]
            store.activePhoneID = "PREVIEW-S24"
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
        case .waitingForPhone:
            let connected = preview(.connected)
            store.phones = connected.phones
            store.activePhoneID = connected.activePhoneID
            store.mirroring.phoneID = connected.activePhoneID
            store.mirroring.phase = .active
            store.mirroring.isWaitingForPhone = true
        }
        return store
    }

    /// A camera folder: two folders, photos and videos taken over a few days,
    /// each with a plain coloured thumbnail, and a document with none.
    private static func previewFiles(in files: FilesState) {
        let folder = FilesState.root + "/DCIM/Camera"
        let now = Date()
        func file(_ name: String, size: UInt64, hoursAgo: Double, editedHoursAgo: Double? = nil,
                  thumbnail: Bool = true) -> PhoneFile {
            PhoneFile(path: "\(folder)/\(name)", name: name, isFolder: false, size: size,
                      modified: now.addingTimeInterval(-3600 * (editedHoursAgo ?? hoursAgo)),
                      created: thumbnail ? now.addingTimeInterval(-3600 * hoursAgo) : nil, hasThumbnail: thumbnail)
        }
        files.isAvailable = true
        files.folder = folder
        files.entries = [
            PhoneFile(path: "\(folder)/.thumbnails", name: ".thumbnails", isFolder: true, size: 0,
                      modified: now.addingTimeInterval(-86400 * 30)),
            PhoneFile(path: "\(folder)/Edited", name: "Edited", isFolder: true, size: 0,
                      modified: now.addingTimeInterval(-86400 * 2)),
            file("20261103_091522.jpg", size: 3_412_220, hoursAgo: 8),
            file("20261103_091530.mp4", size: 48_118_004, hoursAgo: 8),
            file("20261102_184410.jpg", size: 2_904_118, hoursAgo: 23, editedHoursAgo: 1),
            file("20261101_120301.jpg", size: 4_100_772, hoursAgo: 53),
            file("20261031_200945.mp4", size: 120_400_200, hoursAgo: 69),
            file("20261030_073012.jpg", size: 3_002_870, hoursAgo: 106),
            file("Receipt.pdf", size: 212_004, hoursAgo: 30, thumbnail: false),
        ]
        let hues: [CGFloat] = [0.58, 0.08, 0.33, 0.9, 0.15, 0.48]
        for (entry, hue) in zip(files.entries.filter(\.hasThumbnail), hues) {
            files.thumbnails[entry.path] = previewThumbnail(hue: hue)
        }
    }

    /// A small JPEG: a two-colour gradient, a stand-in for a photo.
    private static func previewThumbnail(hue: CGFloat) -> Data? {
        let width = 160, height = 120
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        func color(_ h: CGFloat, _ b: CGFloat) -> CGColor {
            // HSB to RGB, enough for a sample.
            let i = Int(h * 6) % 6, f = h * 6 - CGFloat(Int(h * 6)), s: CGFloat = 0.55
            let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
            let (r, g, bl): (CGFloat, CGFloat, CGFloat) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
            return CGColor(colorSpace: space, components: [r, g, bl, 1])!
        }
        let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.95), color((hue + 0.12).truncatingRemainder(dividingBy: 1), 0.45)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func previewFeatures(connected: Bool) -> [FeatureID: Availability] {
        let overADB: Availability = connected ? .available : .requiresSetup
        return [.mirroring: overADB, .remoteInput: overADB, .clipboard: overADB, .audio: overADB,
                .camera: .planned, .trackpad: .planned, .calls: .planned,
                .files: .planned, .notifications: .planned, .findMac: .planned]
    }
}
#endif
