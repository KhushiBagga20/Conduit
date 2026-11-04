//
//  MediaDeviceTests.swift
//  ConduitCoreTests
//
//  Android's media index and thumbnails against a real phone, when one is
//  named:
//
//      CONDUIT_PHONE=<adb serial> swift test --filter MediaDeviceTests
//
//  It counts what it finds and checks the thumbnails are pictures; it never
//  prints file names or keeps an image.
//

import Foundation
import Testing
@testable import ConduitCore

@Suite("Android's media index on a real phone", .enabled(if: ProcessInfo.processInfo.environment["CONDUIT_PHONE"] != nil))
struct MediaDeviceTests {

    let serial = ProcessInfo.processInfo.environment["CONDUIT_PHONE"] ?? ""

    @Test("the camera folder has dates and thumbnails for photos and videos")
    func cameraFolder() throws {
        let adb = try #require(ADB.locate())
        let folder = "/storage/emulated/0/DCIM/Camera"
        let index = adb.mediaIndex(serial: serial, folder: folder)
        try #require(!index.isEmpty, "the camera folder has no indexed files")

        #expect(index.keys.allSatisfy { ($0 as NSString).deletingLastPathComponent == folder })
        #expect(index.values.allSatisfy { $0.created != nil })

        let images = index.values.filter { $0.kind == .image }
        let videos = index.values.filter { $0.kind == .video }
        print("indexed: \(index.count), images: \(images.count), videos: \(videos.count)")

        for entry in [images.first, videos.first].compactMap({ $0 }) {
            let start = Date()
            let data = try #require(adb.thumbnail(serial: serial, entry: entry))
            print("\(entry.kind) thumbnail: \(data.count) bytes in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            #expect(data.prefix(2) == Data([0xFF, 0xD8]))
        }
    }
}
