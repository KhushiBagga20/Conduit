//
//  DeviceTracker.swift
//  ConduitCore
//
//  Follows `adb track-devices -l`, which pushes the full device list every
//  time it changes. Plugging in, unplugging, authorising and a Wi-Fi drop
//  all show up immediately — no polling.
//
//  The tracker restarts itself if the stream ends, which is what happens
//  when the adb server restarts (another tool ran `adb kill-server`, or a
//  different adb version took over the port).
//

import ConduitMedia
import Foundation

final class DeviceTracker {

    /// Called on the main actor with the complete device list.
    var onUpdate: (([ADBParsing.Device]) -> Void)?

    private let adb: ADB
    private var process: Process?
    private var buffer = Data()
    private var stopped = true
    private var restartDelay: TimeInterval = 1

    init(adb: ADB) {
        self.adb = adb
    }

    func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb.path)
        process.arguments = ["track-devices", "-l"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        buffer.removeAll()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.receive(data) }
        }

        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.process = nil
                guard !self.stopped else { return }
                CoreLog.devices.info("track-devices ended; restarting in \(self.restartDelay)s")
                let delay = self.restartDelay
                self.restartDelay = min(self.restartDelay * 2, 10)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.launch()
                }
            }
        }

        do {
            try process.run()
            self.process = process
            CoreLog.devices.info("tracking devices")
        } catch {
            CoreLog.devices.error("could not start track-devices — \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        for update in ADBParsing.trackUpdates(from: &buffer) {
            restartDelay = 1
            onUpdate?(ADBParsing.deviceList(update))
        }
    }
}
