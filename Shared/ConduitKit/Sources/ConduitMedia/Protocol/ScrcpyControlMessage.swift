//
//  ScrcpyControlMessage.swift
//  ConduitMedia
//
//  Control message encoding for scrcpy v4.1.
//
//  All layouts verified against the pinned v4.1 source:
//    - app/src/control_msg.h:        sc_control_msg_type, SC_POINTER_ID_*
//    - app/src/control_msg.c:        serialisation + write_position()
//    - app/src/util/binary.h:        sc_float_to_u16fp / sc_float_to_i16fp
//    - server/…/control/Controller.java: injectTouch source selection
//
//  Encoding only — no transport. ControlConnection owns the socket.
//

import Foundation

// MARK: - Message Type IDs

/// Control message type IDs.
/// Source: control_msg.h `enum sc_control_msg_type` (0…22 in v4.1).
/// Only the types Conduit currently sends are declared.
enum ScrcpyControlMessageType: UInt8 {
    case injectKeycode           = 0
    case injectText              = 1
    case injectTouchEvent        = 2
    case injectScrollEvent       = 3
    case backOrScreenOn          = 4
    case expandNotificationPanel = 5
    case collapsePanels          = 7
    case getClipboard            = 8
    case setClipboard            = 9
    case setDisplayPower         = 10
    case rotateDevice            = 11
}

// MARK: - Pointer IDs

/// Special pointer IDs understood by the server.
/// Source: control_msg.h SC_POINTER_ID_* (negative values as unsigned).
///
/// `mouse` (-1) is what Conduit uses for the Mac cursor. Controller.java only
/// treats it as a real mouse when the action is HOVER_MOVE or a secondary
/// button is held; a plain left-press/drag falls through to
/// TOOL_TYPE_FINGER + SOURCE_TOUCHSCREEN — i.e. a genuine touch event.
enum ScrcpyPointerID {
    static let mouse:         UInt64 = .max        // -1
    static let genericFinger: UInt64 = .max &- 1   // -2
    static let virtualFinger: UInt64 = .max &- 2   // -3
}

// MARK: - Android Input Constants

/// AMOTION_EVENT_ACTION_* — Android motion event actions.
enum AndroidMotionAction: UInt8 {
    case down      = 0
    case up        = 1
    case move      = 2
    case cancel    = 3
    case hoverMove = 7
    case scroll    = 8
}

/// AMOTION_EVENT_BUTTON_* — Android button state bitmask.
public struct AndroidButton: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let primary   = AndroidButton(rawValue: 1 << 0)
    public static let secondary = AndroidButton(rawValue: 1 << 1)
    public static let tertiary  = AndroidButton(rawValue: 1 << 2)
}

/// AKEY_EVENT_ACTION_* — Android key event actions.
enum AndroidKeyAction: UInt8 {
    case down = 0
    case up   = 1
}

/// AKEYCODE_* — the subset of Android keycodes Conduit sends.
public enum AndroidKeycode: UInt32, Sendable {
    case home       = 3
    case back       = 4
    case dpadUp     = 19
    case dpadDown   = 20
    case dpadLeft   = 21
    case dpadRight  = 22
    case volumeUp   = 24
    case volumeDown = 25
    case power      = 26
    case tab        = 61
    case enter      = 66
    case del        = 67
    case forwardDel = 112
    case moveHome   = 122
    case moveEnd    = 123
    case appSwitch  = 187
}

// MARK: - Control Message

/// A single scrcpy control message, ready to be serialised onto the
/// control socket. Each case maps 1:1 onto an upstream message type.
enum ScrcpyControlMessage {

    /// 32 bytes. Injects a touch/mouse pointer event.
    case injectTouch(
        action: AndroidMotionAction,
        pointerId: UInt64,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Float,
        actionButton: AndroidButton,
        buttons: AndroidButton
    )

    /// 21 bytes. Injects a scroll event at a position.
    /// `hScroll`/`vScroll` are normalised to [-1, 1].
    case injectScroll(
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        hScroll: Float,
        vScroll: Float,
        buttons: AndroidButton
    )

    /// 14 bytes. Injects a key event.
    case injectKeycode(
        action: AndroidKeyAction,
        keycode: AndroidKeycode,
        repeatCount: UInt32,
        metaState: UInt32
    )

    /// 1 + 4 + n bytes. Injects UTF-8 text (as if typed).
    case injectText(String)

    /// 2 bytes. BACK when the screen is on, wake when it is off.
    case backOrScreenOn(action: AndroidKeyAction)

    /// 14 + n bytes. Sets the device clipboard, optionally pasting it
    /// straight into the focused field.
    ///
    /// `sequence` is an ack token the server echoes back on a device
    /// message; 0 means "no acknowledgement wanted", which is what Conduit
    /// uses since it does not read the device channel yet.
    case setClipboard(sequence: UInt64, paste: Bool, text: String)

    /// 2 bytes. Turns the device display on or off while mirroring
    /// continues. Off is scrcpy's "turn screen off" — the phone looks
    /// asleep but still streams and accepts input.
    case setDisplayPower(on: Bool)

    /// 1 byte. Rotates the device display.
    case rotateDevice

    /// 1 byte. Pulls down the notification shade.
    case expandNotificationPanel

    /// 1 byte. Collapses the notification shade.
    case collapsePanels

    // MARK: Limits

    /// Upstream caps injected text length.
    /// Source: control_msg.h SC_CONTROL_MSG_INJECT_TEXT_MAX_LENGTH.
    static let maxTextLength = 300

    /// Clipboard payloads are bounded by the overall message size cap
    /// (SC_CONTROL_MSG_MAX_SIZE) minus this message's 14-byte header.
    static let maxClipboardTextLength = 262144 - 14

    // MARK: Serialisation

    /// Serialise to the exact on-the-wire byte layout the server expects.
    func encode() -> Data {
        var out = Data()

        switch self {

        case let .injectTouch(action, pointerId, x, y, w, h, pressure, actionButton, buttons):
            // [0] type [1] action [2..9] pointer_id
            // [10..21] position [22..23] pressure [24..27] action_button [28..31] buttons
            out.reserveCapacity(32)
            out.append(ScrcpyControlMessageType.injectTouchEvent.rawValue)
            out.append(action.rawValue)
            out.appendBigEndian(pointerId)
            Self.appendPosition(&out, x: x, y: y, width: w, height: h)
            out.appendBigEndian(Self.floatToU16FixedPoint(pressure))
            out.appendBigEndian(actionButton.rawValue)
            out.appendBigEndian(buttons.rawValue)

        case let .injectScroll(x, y, w, h, hScroll, vScroll, buttons):
            // [0] type [1..12] position [13..14] hscroll [15..16] vscroll [17..20] buttons
            out.reserveCapacity(21)
            out.append(ScrcpyControlMessageType.injectScrollEvent.rawValue)
            Self.appendPosition(&out, x: x, y: y, width: w, height: h)
            out.appendBigEndian(UInt16(bitPattern: Self.floatToI16FixedPoint(hScroll)))
            out.appendBigEndian(UInt16(bitPattern: Self.floatToI16FixedPoint(vScroll)))
            out.appendBigEndian(buttons.rawValue)

        case let .injectKeycode(action, keycode, repeatCount, metaState):
            // [0] type [1] action [2..5] keycode [6..9] repeat [10..13] metastate
            out.reserveCapacity(14)
            out.append(ScrcpyControlMessageType.injectKeycode.rawValue)
            out.append(action.rawValue)
            out.appendBigEndian(keycode.rawValue)
            out.appendBigEndian(repeatCount)
            out.appendBigEndian(metaState)

        case let .injectText(text):
            // [0] type [1..4] utf8_length [5…] utf8_bytes
            let payload = Self.clip(text, toByteLimit: Self.maxTextLength)
            out.reserveCapacity(5 + payload.count)
            out.append(ScrcpyControlMessageType.injectText.rawValue)
            out.appendBigEndian(UInt32(payload.count))
            out.append(payload)

        case let .setClipboard(sequence, paste, text):
            // [0] type [1..8] sequence [9] paste [10..13] utf8_length [14…] utf8
            let payload = Self.clip(text, toByteLimit: Self.maxClipboardTextLength)
            out.reserveCapacity(14 + payload.count)
            out.append(ScrcpyControlMessageType.setClipboard.rawValue)
            out.appendBigEndian(sequence)
            out.append(paste ? 1 : 0)
            out.appendBigEndian(UInt32(payload.count))
            out.append(payload)

        case let .backOrScreenOn(action):
            out.reserveCapacity(2)
            out.append(ScrcpyControlMessageType.backOrScreenOn.rawValue)
            out.append(action.rawValue)

        case let .setDisplayPower(on):
            out.reserveCapacity(2)
            out.append(ScrcpyControlMessageType.setDisplayPower.rawValue)
            out.append(on ? 1 : 0)

        case .rotateDevice:
            out.append(ScrcpyControlMessageType.rotateDevice.rawValue)

        case .expandNotificationPanel:
            out.append(ScrcpyControlMessageType.expandNotificationPanel.rawValue)

        case .collapsePanels:
            out.append(ScrcpyControlMessageType.collapsePanels.rawValue)
        }

        return out
    }

    // MARK: - Field Writers

    /// write_position() — 12 bytes: x, y (int32 BE) then width, height (uint16 BE).
    /// Source: control_msg.c write_position().
    private static func appendPosition(
        _ out: inout Data,
        x: Int32,
        y: Int32,
        width: UInt16,
        height: UInt16
    ) {
        out.appendBigEndian(x)
        out.appendBigEndian(y)
        out.appendBigEndian(width)
        out.appendBigEndian(height)
    }

    /// sc_float_to_u16fp — maps [0, 1] onto [0, 0xFFFF].
    /// Source: binary.h. Upstream asserts the input range; Conduit clamps instead
    /// so a stray value can never trap a release build.
    static func floatToU16FixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        let scaled = UInt32(clamped * Float(1 << 16))
        return scaled >= 0xFFFF ? 0xFFFF : UInt16(scaled)
    }

    /// sc_float_to_i16fp — maps [-1, 1] onto [-0x8000, 0x7FFF].
    /// Source: binary.h.
    static func floatToI16FixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        let scaled = Int32(clamped * Float(1 << 15))
        if scaled >= 0x7FFF { return 0x7FFF }
        if scaled <= -0x8000 { return Int16.min }
        return Int16(scaled)
    }

    /// Trim text to a byte limit without splitting a character.
    /// The cap is in BYTES, so a multi-byte character must be dropped
    /// whole rather than cut through the middle of its encoding.
    static func clip(_ text: String, toByteLimit limit: Int) -> Data {
        let payload = Data(text.utf8)
        guard payload.count > limit else { return payload }

        var clipped = text
        while !clipped.isEmpty, Data(clipped.utf8).count > limit {
            clipped.removeLast()
        }
        return Data(clipped.utf8)
    }
}

// MARK: - Big-Endian Append

private extension Data {
    /// Append an integer in network byte order.
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        // Qualified: inside a Data extension, the bare name resolves to
        // Data.withUnsafeBytes rather than the global function.
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
