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
//    - the server exits while mirroring   → relaunch it
//    - its transport vanished             → relaunch on another (USB ↔ Wi-Fi)
//    - no transport left                  → wait; relaunch when the phone returns
//    - a launch fails                     → retry with backoff, then say so
//    - three exits within seconds         → stop and say so
//
//  Every relaunch goes through one scheduler. MEASURED: pulling the cable
//  ends the server process and removes the USB transport at almost the same
//  moment, and handling the two separately launched two servers that raced
//  each other; one pending relaunch at a time cannot.
//

import ConduitMedia
import ConduitState
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
    /// Called when a session that had started is torn down, with the phone.
    var onSessionEnded: (_ phoneID: String) -> Void = { _ in }
    /// Called after a relaunch reattaches, once input works again.
    var onSessionResumed: () -> Void = {}

    /// The adb serial the current server runs over.
    var currentSerial: String? { currentTarget?.serial }

    private var server: ScrcpyServer?
    private var currentTarget: Target?
    private var pendingRelaunch: DispatchWorkItem?
    private var launchFailures = 0
    private var rapidExits = 0

    /// Bumped by start and stop; async work from an older generation is ignored.
    private var generation = 0

    /// Launch attempts before giving up: a few for a fresh start, more for a
    /// session that is already running and worth recovering.
    static let maxStartAttempts = 3
    static let maxRecoveryAttempts = 6

    init(adb: ADB, state: MirroringState) {
        self.adb = adb
        self.state = state
    }

    // MARK: - Commands

    func start(phoneID: String) {
        teardown()
        generation += 1
        rapidExits = 0
        launchFailures = 0

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

        // Waiting for the phone, and it is back.
        if server == nil, let best = available.first {
            CoreLog.mirroring.notice("phone reachable over \(best.transport.rawValue); relaunching")
            launch(on: best, generation: generation)
            return
        }

        // The transport under the running server vanished. Move to another
        // one now rather than waiting for the session to time out. A new
        // transport appearing while the current one works is left alone —
        // switching would interrupt a session that is fine.
        if let current = currentTarget, server != nil, !available.contains(current) {
            if let best = available.first {
                CoreLog.mirroring.notice("moving mirroring from \(current.transport.rawValue) to \(best.transport.rawValue)")
                launch(on: best, generation: generation)
            } else {
                waitForPhone()
            }
        }
    }

    // MARK: - Relaunch scheduling

    nonisolated static func relaunchDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0.5 }
        return min(pow(2, Double(failures - 1)), 8)
    }

    private func scheduleRelaunch(after delay: TimeInterval) {
        pendingRelaunch?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.state.phase != .idle else { return }
            self.pendingRelaunch = nil
            self.relaunch()
        }
        pendingRelaunch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func relaunch() {
        guard let phoneID = state.phoneID else { return }
        if let best = targets(phoneID).first {
            launch(on: best, generation: generation)
        } else {
            waitForPhone()
        }
    }

    /// Keep the session (it keeps retrying its sockets) and relaunch as soon
    /// as `phonesChanged` sees the phone again.
    private func waitForPhone() {
        pendingRelaunch?.cancel()
        pendingRelaunch = nil
        server?.stop()
        server = nil
        currentTarget = nil
        if !state.isWaitingForPhone {
            state.isWaitingForPhone = true
            CoreLog.mirroring.notice("phone not reachable; waiting for it to return")
            record(ActivityEvent(kind: .reconnecting, title: "Waiting for the phone",
                                 detail: "Mirroring resumes when the phone is back over USB or Wi-Fi."))
        }
    }

    // MARK: - Server lifecycle

    private func launch(on target: Target, generation gen: Int) {
        pendingRelaunch?.cancel()
        pendingRelaunch = nil
        server?.stop()

        let options = self.options()
        let configuration = ScrcpyServer.Configuration(serial: target.serial, transport: target.transport,
                                                       options: options)
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
                launchFailures = 0
                attach(port: port, audio: configuration.options.audio, transport: target.transport)
            } catch is CancellationError {
                return
            } catch {
                guard gen == generation, self.server === server else { return }
                self.server = nil
                launchFailures += 1

                let limit = state.session == nil ? Self.maxStartAttempts : Self.maxRecoveryAttempts
                CoreLog.mirroring.error("launch over \(target.transport.rawValue) failed (\(launchFailures)/\(limit)) — \(error.localizedDescription)")
                if launchFailures >= limit {
                    fail(error.localizedDescription)
                } else {
                    scheduleRelaunch(after: Self.relaunchDelay(afterFailures: launchFailures))
                }
            }
        }
    }

    private func attach(port: UInt16, audio: Bool, transport: PhoneTransport) {
        let isFirstAttach = state.session == nil
        let wasWaiting = state.isWaitingForPhone

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
        state.isWaitingForPhone = false
        state.phase = .active

        // A relaunched server starts with the phone's screen on and a fresh
        // control socket; let the owner re-apply session state once input
        // works again.
        if !isFirstAttach {
            let gen = generation
            Task { [weak self, session] in
                for _ in 0 ..< 50 where session.control.state != .connected {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self, gen == self.generation, session.control.state == .connected else { return }
                self.onSessionResumed()
            }
        }

        if isFirstAttach {
            record(ActivityEvent(kind: .mirroringStarted, title: "Mirroring started",
                                 detail: transport == .usb ? "Over USB" : "Over Wi-Fi"))
        } else if wasWaiting {
            record(ActivityEvent(kind: .mirroringStarted, title: "Mirroring resumed",
                                 detail: transport == .usb ? "Over USB" : "Over Wi-Fi"))
        }
    }

    private func serverExited(generation gen: Int, ranFor: TimeInterval) {
        guard gen == generation, state.phase == .active else { return }

        rapidExits = ranFor < 3 ? rapidExits + 1 : 0
        guard rapidExits < 3 else {
            fail("The phone kept stopping the screen server. Unlock the phone and try again.")
            return
        }

        // Removes the exited server's forward so relaunches do not leak ports.
        server?.stop()
        server = nil
        CoreLog.mirroring.notice("server exited after \(Int(ranFor))s; relaunching")
        scheduleRelaunch(after: Self.relaunchDelay(afterFailures: 0))
    }

    private func fail(_ message: String) {
        teardown()
        state.phase = .failed(message)
        record(ActivityEvent(kind: .error, title: "Mirroring stopped", detail: message))
    }

    private func teardown() {
        let endedPhone = state.session != nil ? state.phoneID : nil
        pendingRelaunch?.cancel()
        pendingRelaunch = nil
        server?.stop()
        server = nil
        currentTarget = nil
        state.isWaitingForPhone = false
        state.session?.disconnect()
        state.session = nil
        state.transport = nil
        if let endedPhone { onSessionEnded(endedPhone) }
    }
}
