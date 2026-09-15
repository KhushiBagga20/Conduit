//
//  ControlConnection.swift
//  ConduitMedia
//
//  Control channel transport.
//
//  TCP client for the scrcpy v4.1 control socket. The control socket
//  is the SECOND connection to the same ADB-forwarded port — the server
//  assigns sockets in order: video first, then control.
//
//  The control channel has NO handshake — once connected, it is
//  immediately ready for bidirectional binary control messages.
//
//  Sends control messages (touch, scroll, keys, text) and reads device
//  messages (clipboard changes, acknowledgements).
//

import Foundation
import Network
import Observation

/// TCP client for the scrcpy v4.1 control channel.
///
/// Mirrors the StreamConnection pattern (NWConnection, generation counter,
/// lifecycle-safe callbacks) but is independent and has no protocol parsing —
/// the control socket has no handshake or initial metadata.
@Observable
public final class ControlConnection {

    // MARK: - Configuration

    /// Same host/port as the video connection — scrcpy-server exposes
    /// both video and control on a single LocalServerSocket.
    static let defaultPort: UInt16 = 27183
    static let defaultHost = "127.0.0.1"

    // MARK: - Observable State

    public private(set) var state: SocketState = .disconnected
    public private(set) var errorMessage: String?

    // MARK: - Private

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.khushi.conduit.control", qos: .userInitiated)

    /// Parser for device→client messages. Accessed only from `queue`.
    private var deviceParser: ScrcpyDeviceMessageParser?

    /// Fired on the main thread when the device clipboard changes.
    /// Assigned once by the owner; never cleared by teardown.
    var onDeviceClipboard: ((String) -> Void)?

    /// Generation counter — same pattern as StreamConnection.
    /// Prevents stale NWConnection callbacks from a previous connection
    /// from affecting the current one.
    private var generation: Int = 0

    // MARK: - Public API

    /// Connect to the scrcpy control socket.
    /// MUST be called AFTER the video connection (StreamConnection) is
    /// established — the server accepts video first, then control.
    func connect(host: String = defaultHost, port: UInt16 = defaultPort) {
        disconnect()

        generation += 1
        let gen = generation

        state = .connecting
        errorMessage = nil

        Log.control.info("connecting to \(host):\(port) (gen \(gen))")

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        // Parser runs on `queue`; the generation guard keeps a stale
        // connection's bytes from reaching the current callback.
        deviceParser = ScrcpyDeviceMessageParser { [weak self] message in
            guard let self = self, self.generation == gen else { return }
            self.handleDeviceMessage(message)
        }

        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.handleStateChange(newState, generation: gen)
            }
        }

        connection.start(queue: queue)
    }

    /// Cleanly tear down the control connection.
    func disconnect() {
        connection?.cancel()
        connection = nil
        deviceParser?.reset()
        deviceParser = nil
        if state != .failed {
            state = .disconnected
        }
    }

    // MARK: - Sending

    /// Serialise and write a control message to the socket.
    ///
    /// Silently drops the message if the control channel is not connected —
    /// input events are transient, and queueing them would replay a stale
    /// gesture once the channel came back.
    ///
    /// Safe to call from the main thread: NWConnection.send is thread-safe
    /// and returns immediately, writing on the connection's own queue.
    func send(_ message: ScrcpyControlMessage) {
        guard state == .connected, let connection = connection else { return }

        let data = message.encode()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error = error else { return }
            Log.control.error("send failed — \(error.localizedDescription)")
            DispatchQueue.main.async {
                self?.errorMessage = error.localizedDescription
            }
        })
    }

    // MARK: - Connection State

    private func handleStateChange(_ newState: NWConnection.State, generation gen: Int) {
        switch newState {
        case .ready:
            state = .connected
            errorMessage = nil
            Log.control.notice("connected ✓ (gen \(gen))")
            // No handshake — the control socket is immediately ready.
            // Start reading device messages (clipboard pushes, acks).
            startReceiving(generation: gen)

        case .failed(let error):
            Log.control.error("failed — \(error.localizedDescription)")
            connection?.cancel()
            connection = nil
            state = .failed
            errorMessage = error.localizedDescription

        case .cancelled:
            if state != .failed {
                state = .disconnected
            }
            Log.control.info("cancelled")

        case .preparing:
            state = .connecting

        case .waiting(let error):
            state = .connecting
            Log.control.info("waiting — \(error.localizedDescription)")

        case .setup:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Receiving Device Messages

    /// Read continuously until the connection ends. Mirrors
    /// StreamConnection's loop, including the generation guard that lets a
    /// stale loop self-terminate after a reconnect.
    private func startReceiving(generation gen: Int) {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, self.generation == gen else { return }

            if let data = data, !data.isEmpty {
                // Parser is confined to `queue`, which is where this
                // completion handler already runs.
                self.deviceParser?.receive(data)
            }

            if isComplete || error != nil {
                // The video socket drives reconnection; the control socket
                // going quiet is reported but not acted on here.
                if let error = error {
                    Log.control.error("receive error — \(error.localizedDescription)")
                } else {
                    Log.control.info("server closed the control socket")
                }
                return
            }

            self.startReceiving(generation: gen)
        }
    }

    /// Called on `queue` by the parser. Hops to main for UI-visible work.
    private func handleDeviceMessage(_ message: ScrcpyDeviceMessage) {
        switch message {
        case let .clipboard(text):
            Log.control.info("device clipboard changed (\(text.count) chars)")
            DispatchQueue.main.async { [weak self] in
                self?.onDeviceClipboard?(text)
            }

        case let .acknowledgeClipboard(sequence):
            Log.control.info("clipboard ack seq=\(sequence)")

        case let .uhidOutput(id, data):
            Log.control.info("UHID output id=\(id) (\(data.count) bytes, ignored)")
        }
    }
}
