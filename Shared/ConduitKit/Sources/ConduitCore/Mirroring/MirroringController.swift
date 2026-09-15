//
//  MirroringController.swift
//  ConduitCore
//
//  Owns the phone-screen session end to end: the scrcpy server on the
//  phone, and the MirroringSession on the Mac that talks to it.
//
//  SUPERVISION
//
//  scrcpy's server exits whenever its client goes away — a Wi-Fi blip, a
//  cable pulled, a phone asleep. MirroringSession already retries its
//  sockets with capped backoff; this controller makes sure there is a server
//  for those retries to find:
//
//    - the server exits while mirroring  → launch it again
//    - the phone moved transport          → launch on the new one (USB ↔ Wi-Fi)
//    - the phone disappeared              → wait; launch when it returns
//    - three exits within seconds         → stop and say so
//

import ConduitState
import ConduitMedia
import Foundation

final class MirroringController {

    struct Target: Equatable {
        let serial: String
        let transport: PhoneTransport
    }

    private let adb: ADB
    private let state: MirroringState

    /// Every way a phone can be reached right now, best first (USB before
    /// Wi-Fi). Empty when it is not attached.
    var targets: (String) -> [Target] = { _ in [] }
    var options: () -> MirroringOptions = { MirroringOptions() }
    var onDeviceClipboard: (String) -> Void = { _ in }
    var record: (ActivityEvent) -> Void = { _ in }

    private var server: ScrcpyServer?
    private var currentTarget: Target?
    private var waitingForPhone = false
    private var rapidExits = 0

    /// Bumped by start and stop; async work from an older generation is ignored.
    private var generation = 0

    init(adb: ADB, state: MirroringState) {
        self.adb = adb
        self.state = state
    }

    // MARK: - Commands

    func start(phoneID: String) {
        teardown()
        generation += 1
        rapidExits = 0

        state.phoneID = phoneID
        state.phase = .startingServer

        guard let target = targets(phoneID).first else {
            fail("Connect the phone over USB or Wireless debugging, then try again.")
            return
        }
        launch(on: target, generation: generation)
    }

    func stop() {
        guard state.phase != .idle else { return }
        let wasActive = state.phase == .active
        teardown()
        generation += 1
        state.phase = .idle
        state.phoneID = nil
        if wasActive {
            record(ActivityEvent(kind: .mirroringStopped, title: "Mirroring stopped"))
        }
    }

    func restart() {
        guard let phoneID = state.phoneID else { return }
        start(phoneID: phoneID)
    }

    /// Called whenever the set of attached phones changes.
    func phonesChanged() {
        guard state.phase == .active, let phoneID = state.phoneID else { return }
        let available = targets(phoneID)

        if waitingForPhone, let best = available.first {
            waitingForPhone = false
            CoreLog.mirroring.info("phone is back over \(best.transport.rawValue); relaunching")
            launch(on: best, generation: generation)
            return
        }

        // The transport under the running server vanished but another is
        // still there (cable pulled, Wi-Fi still up): move the session now
        // instead of waiting for it to time out. A new transport appearing
        // while the current one still works is left alone — switching would
        // interrupt a session that is fine.
        if let current = currentTarget, !available.contains(current), let best = available.first {
            CoreLog.mirroring.info("moving mirroring from \(current.transport.rawValue) to \(best.transport.rawValue)")
            launch(on: best, generation: generation)
        }
    }

    // MARK: - Server lifecycle

    private func launch(on target: Target, generation gen: Int) {
        server?.stop()

        let configuration = ScrcpyServer.Configuration(serial: target.serial, options: options())
        let server = ScrcpyServer(adb: adb, configuration: configuration)
        self.server = server
        currentTarget = target

        server.onExit = { [weak self] status, ranFor in
            self?.serverExited(generation: gen, ranFor: ranFor)
        }

        Task {
            do {
                let port = try await server.start()
                guard gen == generation, self.server === server else {
                    server.stop()
                    return
                }
                attach(port: port, audio: configuration.options.audio, transport: target.transport)
            } catch is CancellationError {
                return
            } catch {
                guard gen == generation else { return }
                if state.session != nil {
                    // A relaunch for a session that is still retrying: the
                    // phone is probably mid-transition. Wait for it rather
                    // than ending mirroring the user did not ask to end.
                    waitingForPhone = true
                    CoreLog.mirroring.info("relaunch failed (\(error.localizedDescription)); waiting for the phone")
                } else {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func attach(port: UInt16, audio: Bool, transport: PhoneTransport) {
        let isFirstAttach = state.session == nil

        let session = state.session ?? {
            let session = MirroringSession()
            session.onDeviceClipboard = { [weak self] text in self?.onDeviceClipboard(text) }
            state.session = session
            return session
        }()

        // The session and the server must agree on audio, or the sockets
        // are accepted in the wrong order (video → audio → control).
        session.audioEnabled = audio
        session.connect(host: StreamConnection.defaultHost, port: port)

        state.transport = transport
        state.phase = .active

        if isFirstAttach {
            record(ActivityEvent(kind: .mirroringStarted, title: "Mirroring started",
                                 detail: transport == .usb ? "Over USB" : "Over Wi-Fi"))
        }
    }

    private func serverExited(generation gen: Int, ranFor: TimeInterval) {
        guard gen == generation, state.phase == .active, let phoneID = state.phoneID else { return }

        rapidExits = ranFor < 3 ? rapidExits + 1 : 0
        guard rapidExits < 3 else {
            fail("The phone kept stopping the screen server. Unlock the phone and try again.")
            return
        }

        // Removes the exited server's forward so relaunches do not leak ports.
        server?.stop()
        server = nil
        record(ActivityEvent(kind: .reconnecting, title: "Reconnecting to the phone screen"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, gen == self.generation, self.state.phase == .active else { return }
            if let best = self.targets(phoneID).first {
                self.launch(on: best, generation: gen)
            } else {
                // Keep the session (it is retrying); relaunch when the phone returns.
                self.waitingForPhone = true
                CoreLog.mirroring.info("phone not attached; waiting for it to return")
            }
        }
    }

    private func fail(_ message: String) {
        teardown()
        state.phase = .failed(message)
        record(ActivityEvent(kind: .error, title: "Mirroring stopped", detail: message))
    }

    private func teardown() {
        server?.stop()
        server = nil
        currentTarget = nil
        waitingForPhone = false
        state.session?.disconnect()
        state.session = nil
        state.transport = nil
    }
}
