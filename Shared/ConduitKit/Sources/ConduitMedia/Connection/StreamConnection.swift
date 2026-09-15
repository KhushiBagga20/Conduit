//
//  StreamConnection.swift
//  ConduitMedia
//
//  Transport validation (TCP client)
//  Protocol parsing integration
//  H.264 VideoToolbox decoding
//  Video rendering pipeline
//  Lifecycle hardening
//
//  TCP client that connects to the ADB-forwarded scrcpy server port.
//  Feeds received bytes through: parser → decoder → renderer.
//  Uses a generation counter to prevent stale callbacks from
//  affecting a new connection after disconnect/reconnect.
//

import Foundation
import Network
import Observation

/// Connection states exposed to the UI.
public enum SocketState: String, Sendable {
    case disconnected = "Disconnected"
    case connecting   = "Connecting…"
    case connected    = "Connected"
    case failed       = "Connection Failed"
}

/// TCP client that connects to the scrcpy-server via ADB-forwarded port.
///
/// The host and port come from the owner, which arms an `adb forward` for
/// each scrcpy server it starts; `defaultPort` is scrcpy's own default.
@Observable
public final class StreamConnection {

    // MARK: - Configuration

    /// Default port used by scrcpy's ADB tunnel.
    public static let defaultPort: UInt16 = 27183
    public static let defaultHost = "127.0.0.1"

    // MARK: - Observable State (Transport)

    public private(set) var state: SocketState = .disconnected
    public private(set) var bytesReceived: Int = 0
    public private(set) var errorMessage: String?

    // MARK: - Observable State (Protocol — M1)

    public private(set) var deviceName: String?
    public private(set) var codecName: String?
    public private(set) var videoWidth: Int = 0
    public private(set) var videoHeight: Int = 0
    public private(set) var frameCount: Int = 0

    // MARK: - Observable State (Decoder — M2)

    public private(set) var decodedFrameCount: Int = 0

    // MARK: - Renderer

    /// Video renderer — created on connect, nil when disconnected.
    /// Observed by ContentView to display/hide the PhoneScreenView.
    public private(set) var renderer: VideoRenderer?

    // MARK: - Private

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.khushi.conduit.video", qos: .userInitiated)

    /// Protocol parser — accessed only from `queue`.
    private var parser: ScrcpyVideoParser?

    /// H.264 VideoToolbox decoder — accessed from `queue` and VT callback thread.
    private var decoder: H264Decoder?

    /// Monotonically increasing counter. Incremented on each connect().
    /// Callbacks compare their captured generation to the current value
    /// and exit immediately if they don't match — this prevents stale
    /// VT decode callbacks, parser events, and NWConnection state changes
    /// from a previous connection from affecting the current one.
    private var generation: Int = 0

    // MARK: - One-Shot Callback

    /// Called exactly once when the dummy byte is received from the
    /// scrcpy server, proving the video socket is accepted and alive.
    /// Used by MirroringSession to sequence the control connection.
    /// Cleared after firing, on disconnect, and on teardown.
    var onVideoHandshakeReady: (() -> Void)?

    /// Called when the link drops without the user asking for it: the
    /// server exited (scrcpy is one-shot), the cable was pulled, or the
    /// network died. NOT called by `disconnect()` — a user-initiated
    /// teardown is not something to recover from.
    ///
    /// Deliberately NOT cleared by teardownPipeline(). onVideoHandshakeReady
    /// is, and that produced a real bug (connect() → disconnect() →
    /// teardownPipeline() wiped a callback assigned moments earlier). This
    /// one is assigned once by the owner and must survive every teardown,
    /// since a teardown is exactly when it needs to fire.
    var onUnexpectedDisconnect: (() -> Void)?

    // MARK: - Public API

    /// Establish a TCP connection to the scrcpy server.
    func connect(host: String = defaultHost, port: UInt16 = defaultPort) {
        disconnect()

        generation += 1
        let gen = generation

        state = .connecting
        errorMessage = nil
        bytesReceived = 0
        resetProtocolState()

        // Create parser with event handler.
        // The parser calls onEvent synchronously on `queue`.
        // Generation guard prevents stale events after disconnect.
        parser = ScrcpyVideoParser { [weak self] event in
            guard let self = self, self.generation == gen else { return }
            self.handleParserEvent(event)
        }

        // Create renderer for displaying decoded frames.
        let newRenderer = VideoRenderer()
        renderer = newRenderer

        // Create decoder. The onDecodedFrame callback runs on a
        // VideoToolbox internal thread. Feed frames to the renderer
        // and dispatch count updates to main.
        // Generation guard prevents stale VT callbacks from enqueuing
        // frames after disconnect/reconnect.
        let newDecoder = H264Decoder()
        newDecoder.onDecodedFrame = { [weak self] pixelBuffer, pts in
            guard let self = self, self.generation == gen else { return }
            self.renderer?.enqueue(pixelBuffer: pixelBuffer, pts: pts)
            let count = self.decoder?.decodedFrameCount ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.decodedFrameCount = count
            }
        }
        decoder = newDecoder

        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        let connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        self.connection = connection

        // Generation guard prevents state changes from a cancelled
        // old connection from affecting the new one.
        connection.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.handleStateChange(newState)
            }
        }

        connection.start(queue: queue)
    }

    /// Cleanly tear down the connection.
    func disconnect() {
        connection?.cancel()
        connection = nil
        teardownPipeline()
        if state != .failed {
            state = .disconnected
        }
    }

    // MARK: - Pipeline Teardown

    /// Release the parser, decoder, and renderer.
    /// Safe to call multiple times. Called from disconnect(), and
    /// proactively from failure/completion handlers so resources
    /// are freed immediately rather than on next connect().
    private func teardownPipeline() {
        // Clear one-shot callback to prevent stale firing.
        onVideoHandshakeReady = nil

        // Flush renderer first to clear any displayed frame.
        renderer?.flush()
        renderer = nil

        // Invalidate VT session (blocks briefly for pending callbacks).
        decoder?.invalidate()
        decoder = nil

        // Reset parser buffer.
        parser?.reset()
        parser = nil
    }

    // MARK: - Protocol State Reset

    private func resetProtocolState() {
        deviceName = nil
        codecName = nil
        videoWidth = 0
        videoHeight = 0
        frameCount = 0
        decodedFrameCount = 0
    }

    // MARK: - Connection State

    private func handleStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            state = .connected
            errorMessage = nil
            Log.video.notice("connected to server")
            startReceiving(generation: generation)

        case .failed(let error):
            Log.video.error("failed — \(error.localizedDescription)")
            teardownPipeline()
            connection?.cancel()
            connection = nil
            state = .failed
            errorMessage = error.localizedDescription
            onUnexpectedDisconnect?()

        case .cancelled:
            if state != .failed {
                state = .disconnected
            }
            Log.video.info("cancelled")

        case .preparing:
            state = .connecting

        case .waiting(let error):
            // MEASURED, not assumed: connecting to a closed port reports
            // .waiting(ECONNREFUSED) and NEVER .failed — and NWConnection
            // does not recover on its own when the port later opens (still
            // .waiting 9s after a listener started). Leaving it waiting
            // would strand a reconnect forever, which is precisely the
            // "server came back but the client didn't" failure.
            //
            // The endpoint is always localhost via `adb forward`, where a
            // real connect is instantaneous, so .waiting means "nothing is
            // listening yet". Treat it as a failed attempt and let the
            // owner retry with a fresh NWConnection.
            Log.video.info("waiting — \(error.localizedDescription) (treating as attempt failure)")
            teardownPipeline()
            connection?.cancel()
            connection = nil
            state = .failed
            errorMessage = error.localizedDescription
            onUnexpectedDisconnect?()

        case .setup:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Data Reception

    /// Read data continuously until the connection ends.
    /// The `gen` parameter ties this receive loop to a specific
    /// connection — if the generation changes (disconnect/reconnect),
    /// the loop self-terminates.
    private func startReceiving(generation gen: Int) {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, self.generation == gen else { return }

            if let data = data, !data.isEmpty {
                let count = data.count
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    self.bytesReceived += count
                }

                // Feed bytes into the protocol parser (runs on `queue`).
                self.parser?.receive(data)
            }

            if isComplete {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    Log.video.info("server closed connection")
                    self.teardownPipeline()
                    self.connection?.cancel()
                    self.connection = nil
                    self.state = .disconnected
                    self.onUnexpectedDisconnect?()
                }
                return
            }

            if let error = error {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    Log.video.error("receive error — \(error.localizedDescription)")
                    self.teardownPipeline()
                    self.connection?.cancel()
                    self.connection = nil
                    self.state = .failed
                    self.errorMessage = error.localizedDescription
                    self.onUnexpectedDisconnect?()
                }
                return
            }

            // Continue reading
            self.startReceiving(generation: gen)
        }
    }

    // MARK: - Parser Event Handling

    /// Called synchronously by the parser on `queue`.
    /// Dispatches observable state updates to the main thread.
    private func handleParserEvent(_ event: ScrcpyParserEvent) {
        switch event {
        case .dummyByteReceived:
            Log.wire.info("dummy byte received — video handshake ready")
            // Fire the one-shot callback on main thread.
            // This signals MirroringSession that the video socket
            // is accepted and alive — safe to connect the control socket.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let callback = self.onVideoHandshakeReady
                self.onVideoHandshakeReady = nil
                callback?()
            }

        case .deviceInfoReceived(let info):
            Log.wire.infoRedacted("Device", info.deviceName)
            DispatchQueue.main.async { [weak self] in
                self?.deviceName = info.deviceName
            }

        case .codecDetected(let codec):
            Log.wire.info("Codec: \(codec.description)")
            DispatchQueue.main.async { [weak self] in
                self?.codecName = codec.description
            }

        case .videoSessionReceived(let session):
            Log.wire.info("Video: \(session.description)")
            DispatchQueue.main.async { [weak self] in
                self?.videoWidth = session.width
                self?.videoHeight = session.height
            }

        case .videoFrameReceived(let frame):
            // Feed frame to the H.264 decoder.
            decoder?.processFrame(frame)

            // Update parsed frame counter in the UI.
            let count = parser?.frameCount ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.frameCount = count
            }

        case .parserError(let error):
            Log.wire.info("\(error.description)")
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = error.description
            }
        }
    }
}
