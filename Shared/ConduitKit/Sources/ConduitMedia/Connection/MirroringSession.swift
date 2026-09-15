//
//  MirroringSession.swift
//  ConduitMedia
//
//  Sequences video and control connections.
//  Owns the InputController that drives the phone.
//
//  scrcpy v4.1 exposes video and control on a single LocalServerSocket.
//  The server calls accept() in order: video first, then control.
//  This session connects in the correct order:
//
//    1. StreamConnection.connect()    → video socket (accept₁)
//    2. Wait for dummy byte (application-level handshake)
//    3. ControlConnection.connect()   → control socket (accept₂)
//
//  The dummy byte — not TCP .ready — is the sequencing barrier.
//  TCP .ready only means ADB forwarding is established, not that the
//  server has accepted the connection and is ready for the second socket.
//
//  Owns all three connections and exposes their combined observable state.
//  Clipboard policy is not decided here: device clipboard changes are handed
//  to `onDeviceClipboard`, and the owner decides whether the Mac pasteboard
//  follows.
//

import Foundation
import Observation

/// Coordinates the video (StreamConnection) and control (ControlConnection)
/// connections to the scrcpy server. Ensures correct socket ordering.
@Observable
public final class MirroringSession {

    // MARK: - Connections

    public let stream = StreamConnection()
    public let audio = AudioConnection()
    public let control = ControlConnection()

    /// Whether to open the audio socket. This MUST match the server's
    /// `audio=` setting: the server accepts video → audio → control in a
    /// fixed order, so if it was launched without audio, opening a third
    /// socket would make our "audio" socket the control socket and leave
    /// the real control socket stranded in the backlog.
    public var audioEnabled = true

    // MARK: - Input

    /// Translates Mac cursor/keyboard events into scrcpy control messages.
    /// Created once and reused across connect cycles — it holds no
    /// per-connection state beyond the in-flight gesture, which it drops
    /// on disconnect.
    public let input: InputController

    // MARK: - Init

    public init() {
        input = InputController(control: control, stream: stream)

        // Assigned ONCE, here, and never cleared. StreamConnection
        // deliberately does not wipe this in teardownPipeline() — a
        // teardown is precisely when it must fire.
        stream.onUnexpectedDisconnect = { [weak self] in
            self?.handleUnexpectedDisconnect()
        }

        // Copy-on-phone → paste-on-Mac. Also assigned once and never
        // cleared, for the same reason as the disconnect hook.
        control.onDeviceClipboard = { [weak self] text in
            self?.receiveDeviceClipboard(text)
        }
    }

    // MARK: - Clipboard

    /// Number of clipboard pushes accepted from the device. Diagnostics only.
    public private(set) var deviceClipboardCount = 0

    /// Called on the main thread with each genuine device clipboard change —
    /// never with the echo of text this session just sent. Assigned once by
    /// the owner, which applies the user's clipboard settings.
    public var onDeviceClipboard: ((String) -> Void)?

    private func receiveDeviceClipboard(_ text: String) {
        guard !text.isEmpty else { return }

        // Ignore the echo of our own SET_CLIPBOARD (see lastSentClipboard).
        if let sent = input.lastSentClipboard, sent == text {
            Log.clipboard.info("ignoring echo of our own push")
            return
        }

        deviceClipboardCount += 1
        Log.clipboard.info("device → Mac (\(text.count) chars)")
        onDeviceClipboard?(text)
    }

    // MARK: - Auto-Reconnect

    /// True while waiting to retry after a drop. Drives the UI.
    public private(set) var isReconnecting = false

    /// Consecutive failed attempts since the last good connection.
    public private(set) var reconnectAttempt = 0

    /// Whether drops should be retried. Set by connect(), cleared by
    /// disconnect() — so a deliberate Disconnect never triggers a retry.
    private var autoReconnectEnabled = false

    private var pendingReconnect: DispatchWorkItem?
    private var lastHost = StreamConnection.defaultHost
    private var lastPort = StreamConnection.defaultPort

    /// Cap on the backoff interval. The server may be down for a while
    /// (unplugged cable, `--watch` waiting for the device), so retries
    /// continue indefinitely rather than giving up — just not faster
    /// than this once the link has clearly gone.
    private static let maxReconnectDelay: TimeInterval = 5.0

    private func handleUnexpectedDisconnect() {
        guard autoReconnectEnabled else { return }

        Log.session.notice("link dropped — scheduling reconnect")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        pendingReconnect?.cancel()

        reconnectAttempt += 1
        isReconnecting = true

        // 0.5s, 1s, 2s, 4s, then capped. Fast enough that a quick
        // replug feels instant, slow enough not to spin on a long outage.
        let backoff = min(
            0.5 * pow(2.0, Double(reconnectAttempt - 1)),
            Self.maxReconnectDelay
        )

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.autoReconnectEnabled else { return }
            Log.session.notice("reconnect attempt \(self.reconnectAttempt)")
            self.performConnect(host: self.lastHost, port: self.lastPort)
        }
        pendingReconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: work)
    }

    private func cancelPendingReconnect() {
        pendingReconnect?.cancel()
        pendingReconnect = nil
    }

    // MARK: - Coordinator State

    /// Overall coordinator state — reflects the combined status.
    public var statusSummary: String {
        let v = stream.state.rawValue
        let c = control.state.rawValue
        return "Video: \(v) | Control: \(c)"
    }

    // MARK: - Private

    /// Generation counter for the coordinator itself.
    /// Prevents a stale onVideoHandshakeReady callback from a previous
    /// connect() cycle from triggering a control connection on a new cycle.
    private var generation: Int = 0

    // MARK: - Public API

    /// Connect to the scrcpy server: video first, then control.
    /// User-initiated — this is what arms auto-reconnect.
    public func connect(
        host: String = StreamConnection.defaultHost,
        port: UInt16 = StreamConnection.defaultPort
    ) {
        lastHost = host
        lastPort = port
        autoReconnectEnabled = true
        reconnectAttempt = 0
        isReconnecting = false

        performConnect(host: host, port: port)
    }

    /// The actual connect sequence, shared by the user's Connect button and
    /// by automatic retries. Kept separate so a retry does not reset the
    /// attempt counter or re-arm anything the user did not ask for.
    private func performConnect(host: String, port: UInt16) {
        cancelPendingReconnect()
        teardownTransports()

        generation += 1
        let gen = generation

        Log.session.info("starting connection sequence (gen \(gen))")

        // Start the video connection FIRST. The server's first accept()
        // will assign this as the video socket.
        stream.connect(host: host, port: port)

        // Install the handshake callback AFTER connect().
        //
        // Ordering is load-bearing: StreamConnection.connect() begins with
        // disconnect() → teardownPipeline(), which clears
        // onVideoHandshakeReady. Assigning before connect() would set the
        // callback and then immediately have it wiped, so the control
        // socket would never open.
        //
        // Assigning after is safe because connect() only reaches
        // NWConnection.start(); the dummy byte cannot be parsed and
        // delivered — it hops through the network queue and back to main —
        // before this synchronous main-thread statement completes.
        stream.onVideoHandshakeReady = { [weak self] in
            guard let self = self, self.generation == gen else {
                Log.session.info("stale handshake callback ignored (gen mismatch)")
                return
            }

            // The dummy byte is the first proof the link genuinely works,
            // so this is the right place to call the retry sequence done.
            self.reconnectAttempt = 0
            self.isReconnecting = false

            // The server accepts video → audio → control, in that order, on
            // one listening socket. Each step waits for the previous socket
            // to be accepted so the assignment can never be transposed.
            guard self.audioEnabled else {
                Log.session.info("video ready → connecting control (audio off, gen \(gen))")
                self.control.connect(host: host, port: port)
                return
            }

            Log.session.info("video ready → connecting audio (gen \(gen))")

            // Fires on success AND on failure, so a refused or unavailable
            // audio socket can never strand the control socket — losing
            // audio must not cost us the ability to touch the phone.
            self.audio.onReady = { [weak self] in
                guard let self = self, self.generation == gen else {
                    Log.session.info("stale audio callback ignored")
                    return
                }
                Log.session.info("audio socket settled → connecting control (gen \(gen))")
                self.control.connect(host: host, port: port)
            }
            self.audio.connect(host: host, port: port)
        }
    }

    /// Disconnect both connections. User-initiated — disarms auto-reconnect,
    /// so a deliberate Disconnect stays disconnected.
    public func disconnect() {
        // The server restores display power when it exits, but a user-driven
        // disconnect can leave the phone dark if the server keeps running
        // (--watch). Ask for it back while the socket is still open.
        if control.state == .connected, !input.isDisplayOn {
            input.setDisplayPower(on: true)
        }

        autoReconnectEnabled = false
        cancelPendingReconnect()
        isReconnecting = false
        reconnectAttempt = 0

        teardownTransports()

        Log.session.notice("disconnected")
    }

    /// Tear down both sockets without touching auto-reconnect state.
    /// Used by disconnect() and before each (re)connect attempt.
    private func teardownTransports() {
        // Clear the callback first to prevent it from firing during teardown.
        stream.onVideoHandshakeReady = nil

        // Drop any in-flight gesture so a reconnect starts clean.
        input.reset()

        audio.onReady = nil
        audio.disconnect()
        control.disconnect()
        stream.disconnect()

        Log.session.notice("disconnected")
    }
}
