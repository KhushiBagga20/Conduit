//
//  ScrcpyServer.swift
//  ConduitCore
//
//  One scrcpy-server process on the phone, reached through its own adb
//  forward.
//
//  Every server gets a random `scid`, which gives it a unique abstract
//  socket (`scrcpy_<scid>`) and forward. Two servers — say a mirroring
//  session and, later, a camera or a background clipboard session — can
//  then run side by side without fighting over scrcpy's default socket.
//
//  The server is one-shot by design: it exits when its client disconnects.
//  Deciding whether to launch it again is the owner's job, not this type's.
//
//  MEASURED on a Galaxy S24 Ultra: the server deletes its own jar from the
//  phone as soon as it has loaded it. The jar is therefore pushed before
//  every launch, and each server gets its own path — two servers launched
//  close together from one shared path race, and the second one aborts
//  because the first has already removed the file it is loading.
//

import ConduitMedia
import ConduitState
import CryptoKit
import Foundation

final class ScrcpyServer {

    nonisolated static let version = "4.1"
    nonisolated static let expectedSHA256 = "deacb991ed2509715160ffdc7907e47b4160eb30d1566217e9047fd5b8850cae"

    nonisolated enum VideoSource: Sendable, Equatable {
        case display
        case camera(facing: CameraFacing)
    }

    nonisolated enum CameraFacing: String, Sendable {
        case back, front
    }

    nonisolated struct Configuration: Sendable {
        var serial: String
        var transport: PhoneTransport = .usb
        var scid: UInt32 = UInt32.random(in: 1 ... 0x7FFF_FFFF)
        var options: MirroringOptions
        var videoSource: VideoSource = .display
        var control = true

        /// The server command line, verified against scrcpy v4.1's
        /// Options.java. `scid` is parsed as hex and must fit in 31 bits.
        var arguments: [String] {
            var args = [
                "scid=\(String(format: "%08x", scid))",
                "log_level=info",
                "video=true",
                "audio=\(options.audio)",
                "audio_codec=raw",
                "control=\(control)",
                "tunnel_forward=true",
                "video_bit_rate=\(options.effectiveBitRate)",
                "max_size=\(options.maxSize(over: transport))",
                "max_fps=\(options.maxFPS)",
                // stay_awake only works while the phone is charging; over
                // Wi-Fi the phone would sleep mid-session and drop the link.
                // keep_active signals user activity instead, on any transport.
                "stay_awake=\(options.stayAwake)",
                "keep_active=\(options.stayAwake)",
            ]
            if case .camera(let facing) = videoSource {
                args += ["video_source=camera", "camera_facing=\(facing.rawValue)"]
            }
            return args
        }

        var socketName: String { "scrcpy_\(String(format: "%08x", scid))" }

        /// Where this server's jar is pushed. Unique per server: see the
        /// file header for why a shared path is not safe.
        var devicePath: String { "/data/local/tmp/conduit-scrcpy-\(String(format: "%08x", scid)).jar" }
    }

    nonisolated enum ServerError: LocalizedError {
        case missingBinary
        case checksumMismatch
        case pushFailed(String)
        case forwardFailed
        case exitedEarly(Int32)

        var errorDescription: String? {
            switch self {
            case .missingBinary: "The screen server is missing from Conduit. Reinstall Conduit."
            case .checksumMismatch: "The screen server in Conduit is damaged. Reinstall Conduit."
            case .pushFailed(let detail): "Couldn't copy the screen server to the phone: \(detail)"
            case .forwardFailed: "Couldn't open a connection to the phone."
            case .exitedEarly(let status): "The phone stopped the screen server (status \(status))."
            }
        }
    }

    let configuration: Configuration
    private let adb: ADB

    /// Local port forwarded to this server's socket, once started.
    private(set) var port: UInt16?
    private(set) var isRunning = false

    /// Called on the main actor when the server process ends, with how long
    /// it ran. Not called after `stop()`.
    var onExit: ((Int32, TimeInterval) -> Void)?

    private var process: Process?
    private var launchedAt = Date()
    private var stopped = false

    init(adb: ADB, configuration: Configuration) {
        self.adb = adb
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// Push the server, arm the forward and launch. Returns the local port
    /// once the server reports it is listening.
    func start() async throws -> UInt16 {
        let adb = self.adb
        let configuration = self.configuration

        let port = try await Task.detached { () throws -> UInt16 in
            try Self.prepare(adb: adb, configuration: configuration)
        }.value

        guard !stopped else { throw CancellationError() }
        self.port = port
        try await launch(port: port)
        return port
    }

    func stop() {
        stopped = true
        isRunning = false
        process?.terminate()
        process = nil

        if let port {
            let adb = self.adb, serial = configuration.serial
            Task.detached { adb.removeForward(port: port, serial: serial) }
        }
    }

    // MARK: - Private

    nonisolated private static func prepare(adb: ADB, configuration: Configuration) throws -> UInt16 {
        guard let jar = Bundle.module.url(forResource: "scrcpy-server-v\(version)", withExtension: nil),
              let bytes = try? Data(contentsOf: jar)
        else { throw ServerError.missingBinary }

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw ServerError.checksumMismatch }

        let push = adb.push(jar, to: configuration.devicePath, serial: configuration.serial)
        guard push.ok else {
            throw ServerError.pushFailed(push.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let port = adb.forward(serial: configuration.serial, toAbstractSocket: configuration.socketName) else {
            throw ServerError.forwardFailed
        }
        return port
    }

    private func launch(port: UInt16) async throws {
        let command = (["CLASSPATH=\(configuration.devicePath)", "app_process", "/",
                        "com.genymobile.scrcpy.Server", Self.version] + configuration.arguments)
            .joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb.path)
        process.arguments = ["-s", configuration.serial, "shell", command]
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let ready = ReadyLatch()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // The server prints "Device: …" as it starts listening. MEASURED:
            // the line can come a moment before the socket accepts, so the
            // first connect would bounce and retry; a short grace avoids it.
            if String(decoding: data, as: UTF8.self).contains("Device:") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    ready.fire(.success(()))
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                ready.fire(.failure(ServerError.exitedEarly(status)))
                guard let self, self.process === finished else { return }
                self.process = nil
                self.isRunning = false
                let ranFor = Date().timeIntervalSince(self.launchedAt)
                CoreLog.server.info("server exited with status \(status) after \(Int(ranFor))s")
                if !self.stopped { self.onExit?(status, ranFor) }
            }
        }

        try process.run()
        self.process = process
        launchedAt = Date()
        isRunning = true
        CoreLog.server.info("launched scrcpy-server \(Self.version) (\(configuration.socketName)) on local port \(port)")

        // Some builds print nothing before the first client connects; a
        // server still alive after a few seconds is listening.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            ready.fire(.success(()))
        }

        try await ready.wait()
    }
}

/// Resolves exactly once: the first of "ready", "exited" or the timeout.
private final class ReadyLatch {
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func fire(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func wait() async throws {
        if let result { return try result.get() }
        try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}
