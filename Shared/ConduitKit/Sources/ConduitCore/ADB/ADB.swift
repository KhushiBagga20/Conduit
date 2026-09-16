//
//  ADB.swift
//  ConduitCore
//
//  Runs the user's own adb. Every blocking call is `nonisolated` and must be
//  made off the main actor.
//

import ConduitMedia
import ConduitState
import Darwin
import Foundation

nonisolated struct ADB: Sendable {

    let path: String

    /// The adb the user runs in Terminal, in preference order. Two adb
    /// binaries of different versions kill each other's server on every call,
    /// so matching Terminal matters more than picking the newest.
    static func locate() -> ADB? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(ADB.init)
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
        var combined: String { stdout + stderr }
    }

    /// Run adb to completion.
    ///
    /// Output is collected with readability handlers rather than
    /// readDataToEndOfFile(): if this call happens to spawn the adb server,
    /// the daemon can inherit the pipe and hold it open, and a blocking read
    /// would never see EOF.
    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 20) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = OutputBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.appendOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.appendErr(data) }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
        }

        // Let the last chunk land before detaching the handlers.
        Thread.sleep(forTimeInterval: 0.03)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let status = process.isRunning ? -1 : process.terminationStatus
        return Output(status: status, stdout: buffer.stdout, stderr: buffer.stderr)
    }

    /// Start the adb server detached from any pipe, so later calls never
    /// spawn it with a pipe attached.
    func startServer() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["start-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Commands

    func properties(of serial: String) -> ADBParsing.PhoneProperties? {
        let out = run(["-s", serial, "shell", ADBParsing.phonePropertiesCommand], timeout: 10)
        guard out.ok else { return nil }
        return ADBParsing.phoneProperties(out.stdout, fallbackSerial: serial)
    }

    func connect(host: String, port: UInt16) -> Bool {
        ADBParsing.connectSucceeded(run(["connect", "\(host):\(port)"], timeout: 12).combined)
    }

    nonisolated static let companionPackage = "com.khushi.conduit"
    nonisolated static let secureSettingsPermission = "android.permission.WRITE_SECURE_SETTINGS"

    /// Whether Conduit for Android is installed, and whether it may change
    /// secure settings. `pm list packages` is avoided: on phones with a
    /// Secure Folder profile it fails for the shell user.
    func companionAppStatus(serial: String) -> CompanionAppStatus? {
        let path = run(["-s", serial, "shell", "pm", "path", Self.companionPackage], timeout: 8)
        guard path.status != -1 else { return nil }
        guard path.stdout.contains("package:") else { return .notInstalled }
        let dump = run(["-s", serial, "shell", "dumpsys", "package", Self.companionPackage], timeout: 10)
        return .installed(canManageSettings: ADBParsing.permissionGranted(Self.secureSettingsPermission, in: dump.stdout))
    }

    func grantCompanionSettingsControl(serial: String) -> Bool {
        run(["-s", serial, "shell", "pm", "grant", Self.companionPackage, Self.secureSettingsPermission], timeout: 10).ok
    }

    /// Arm adb's TCP mode, so the phone accepts connections on every network
    /// it joins — the only way in over its own hotspot, where Android turns
    /// Wireless debugging off. It lasts until the phone restarts, or
    /// `restoreUSBMode` closes it.
    func armTCPMode(serial: String, port: UInt16) -> Bool {
        ADBParsing.tcpModeArmed(run(["-s", serial, "tcpip", String(port)], timeout: 15).combined, port: port)
    }

    /// Put adbd back to USB only, closing the TCP port.
    func restoreUSBMode(serial: String) -> Bool {
        ADBParsing.usbModeRestored(run(["-s", serial, "usb"], timeout: 15).combined)
    }

    /// The port adb's TCP mode is listening on, or nil when it is off. The
    /// port can be opened or closed outside Conduit, and the phone forgets
    /// it when it restarts, so this is read rather than assumed.
    func tcpPort(serial: String) -> UInt16? {
        let output = run(["-s", serial, "shell", "getprop", "service.adb.tcp.port"], timeout: 8)
        guard output.ok, let port = UInt16(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0
        else { return nil }
        return port
    }

    /// The phone's hardware serial, to check who answered at an address.
    func hardwareSerial(of serial: String) -> String? {
        let output = run(["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 8)
        guard output.ok else { return nil }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "null" ? nil : text
    }

    /// Drop a network transport. Harmless for one that is already gone.
    func disconnect(_ serial: String) {
        run(["disconnect", serial], timeout: 5)
    }

    func push(_ local: URL, to remote: String, serial: String) -> Output {
        run(["-s", serial, "push", local.path, remote], timeout: 60)
    }

    /// Forward a free local port to an abstract socket on the phone.
    func forward(serial: String, toAbstractSocket name: String) -> UInt16? {
        let out = run(["-s", serial, "forward", "tcp:0", "localabstract:\(name)"], timeout: 10)
        return out.ok ? ADBParsing.allocatedPort(out.stdout) : nil
    }

    func removeForward(port: UInt16, serial: String) {
        run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
    }
}

/// Thread-safe accumulation for pipe handlers.
nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.withLock { out.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { err.append(data) } }
    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
}

nonisolated enum CoreLog {
    static let adb = ConduitLogger("adb")
    static let devices = ConduitLogger("devices")
    static let discovery = ConduitLogger("wireless-discovery")
    static let server = ConduitLogger("scrcpy-server")
    static let mirroring = ConduitLogger("mirroring-owner")
    static let engine = ConduitLogger("engine")
}
