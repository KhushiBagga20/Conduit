//
//  ClipboardSession.swift
//  ConduitMedia
//
//  The phone's clipboard on its own, through a scrcpy server started with no
//  video and no audio. Its control socket is then the only one, and the
//  server is told to send no preamble on it — so it is a bare control
//  connection, with nothing to parse before the first device message.
//
//  Android lets no ordinary app read the clipboard in the background, but
//  scrcpy's server runs as the adb shell, which may. That is what lets the
//  phone's clipboard reach the Mac without mirroring.
//

import Foundation

public final class ClipboardSession {

    private let control = ControlConnection()

    public init() {}

    /// Called on the main thread with each new text on the phone's clipboard.
    public var onDeviceClipboard: ((String) -> Void)? {
        get { control.onDeviceClipboard }
        set { control.onDeviceClipboard = newValue }
    }

    public var isConnected: Bool { control.state == .connected }

    public func connect(port: UInt16) {
        control.connect(port: port)
    }

    public func disconnect() {
        control.disconnect()
    }

    /// Put text on the phone's clipboard, without pasting it anywhere.
    public func setPhoneClipboard(_ text: String) {
        control.send(.setClipboard(sequence: 0, paste: false, text: text))
    }
}
