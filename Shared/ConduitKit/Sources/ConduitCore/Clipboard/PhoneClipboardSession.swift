//
//  PhoneClipboardSession.swift
//  ConduitCore
//
//  Keeps the phone's clipboard flowing to this Mac whenever adb can reach
//  the phone and nothing is mirroring — a mirroring session carries the
//  clipboard itself. One small scrcpy server with no video; it is one-shot,
//  so it is launched again when it ends, with backoff.
//

import ConduitMedia
import ConduitState
import Foundation

@MainActor
final class PhoneClipboardSession {

    private let adb: ADB
    private var server: ScrcpyServer?
    private var session: ClipboardSession?
    private var restart: Task<Void, Never>?
    private var failures = 0

    /// The phone it runs on, or nil while stopped.
    private(set) var serial: String?

    /// New text on the phone's clipboard. Main thread.
    var onClipboard: (String) -> Void = { _ in }
    var onConnectionChange: () -> Void = {}

    var isConnected: Bool { session?.isConnected == true }

    init(adb: ADB) {
        self.adb = adb
    }

    /// Run on this phone, or stop with nil. The same serial again changes
    /// nothing.
    func run(on serial: String?) {
        guard serial != self.serial else { return }
        stop()
        self.serial = serial
        guard serial != nil else { return }
        failures = 0
        launch()
    }

    func stop() {
        restart?.cancel()
        restart = nil
        session?.disconnect()
        session = nil
        server?.stop()
        server = nil
        serial = nil
        onConnectionChange()
    }

    /// Put text on the phone's clipboard over adb. False if not connected.
    func setPhoneClipboard(_ text: String) -> Bool {
        guard let session, session.isConnected else { return false }
        session.setPhoneClipboard(text)
        return true
    }

    // MARK: - Private

    private func launch() {
        guard let serial else { return }
        let server = ScrcpyServer(adb: adb, configuration: ScrcpyServer.Configuration(
            serial: serial, options: MirroringOptions(), clipboardOnly: true))
        server.onExit = { [weak self, weak server] _, ranFor in
            guard let self, let server, self.server === server else { return }
            ended(ranFor: ranFor)
        }
        self.server = server

        Task { [weak self] in
            do {
                let port = try await server.start()
                guard let self, self.server === server else {
                    server.stop()
                    return
                }
                let session = ClipboardSession()
                session.onDeviceClipboard = { [weak self] text in self?.onClipboard(text) }
                session.connect(port: port)
                self.session = session
                CoreLog.engine.notice("the phone's clipboard reaches this Mac without mirroring")
                // The control connection reports ready on its own queue.
                try? await Task.sleep(for: .milliseconds(400))
                onConnectionChange()
            } catch {
                guard let self, self.server === server else { return }
                CoreLog.engine.notice("the background clipboard session could not start")
                ended(ranFor: 0)
            }
        }
    }

    private func ended(ranFor: TimeInterval) {
        session?.disconnect()
        session = nil
        server?.stop()
        server = nil
        onConnectionChange()
        guard serial != nil else { return }

        // A session that ran a while was fine: start counting again.
        failures = ranFor > 30 ? 1 : failures + 1
        guard failures <= 6 else {
            CoreLog.engine.error("gave up on the background clipboard session after repeated failures")
            return
        }
        let delay = min(Double(1 << failures), 30)
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.launch()
        }
    }
}
