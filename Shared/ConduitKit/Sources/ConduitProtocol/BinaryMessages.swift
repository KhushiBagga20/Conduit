//
//  BinaryMessages.swift
//  ConduitProtocol
//
//  Bodies for the binary channels. Spec: Shared/Protocol/README.md §7.
//
//  Input is binary rather than JSON because of rate: a trackpad drag at
//  120 Hz is a stream of 10-byte frames, and JSON would multiply that
//  several times over for no benefit.
//

import Foundation

// MARK: - Input (phone → Mac)

public enum InputType: UInt8, Sendable, CaseIterable {
    case pointerMove = 0
    case pointerButton = 1
    case scroll = 2
    case key = 3
}

public enum PointerButton: UInt8, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

/// A physical control on the phone, described by intent rather than by
/// Android keycode — the Mac decides what it does.
public enum PhoneKey: UInt16, Sendable {
    case volumeUp = 0
    case volumeDown = 1
}

public enum InputEvent: Sendable, Equatable {
    /// Relative movement: the phone cannot know the Mac's desktop size.
    case move(dx: Int16, dy: Int16)
    case button(PointerButton, down: Bool)
    case scroll(dx: Int16, dy: Int16)
    case key(PhoneKey, down: Bool)

    public var frame: Frame {
        var w = ByteWriter()
        let type: InputType
        switch self {
        case let .move(dx, dy):
            type = .pointerMove; w.i16(dx); w.i16(dy)
        case let .button(button, down):
            type = .pointerButton; w.u8(button.rawValue); w.u8(down ? 1 : 0)
        case let .scroll(dx, dy):
            type = .scroll; w.i16(dx); w.i16(dy)
        case let .key(key, down):
            type = .key; w.u16(key.rawValue); w.u8(down ? 1 : 0)
        }
        return Frame(channel: .input, type: type.rawValue, payload: w.data)
    }

    /// Decode an input frame. Returns nil for a malformed body.
    public init?(frame: Frame) {
        guard frame.channel == .input, let type = InputType(rawValue: frame.type) else { return nil }
        var r = ByteReader(frame.payload)
        switch type {
        case .pointerMove:
            guard let dx = r.i16(), let dy = r.i16() else { return nil }
            self = .move(dx: dx, dy: dy)
        case .pointerButton:
            guard let raw = r.u8(), let button = PointerButton(rawValue: raw), let down = r.u8() else { return nil }
            self = .button(button, down: down != 0)
        case .scroll:
            guard let dx = r.i16(), let dy = r.i16() else { return nil }
            self = .scroll(dx: dx, dy: dy)
        case .key:
            guard let raw = r.u16(), let key = PhoneKey(rawValue: raw), let down = r.u8() else { return nil }
            self = .key(key, down: down != 0)
        }
    }
}

// MARK: - Haptic (Mac → phone)

public enum HapticType: UInt8, Sendable {
    case vibrate = 0
}

public struct Vibration: Sendable, Equatable {
    public var durationMs: UInt16
    /// 1–255.
    public var amplitude: UInt8

    public init(durationMs: UInt16, amplitude: UInt8) {
        self.durationMs = durationMs
        self.amplitude = max(amplitude, 1)
    }

    public var frame: Frame {
        var w = ByteWriter()
        w.u16(durationMs)
        w.u8(amplitude)
        return Frame(channel: .haptic, type: HapticType.vibrate.rawValue, payload: w.data)
    }

    public init?(frame: Frame) {
        guard frame.channel == .haptic, frame.type == HapticType.vibrate.rawValue else { return nil }
        var r = ByteReader(frame.payload)
        guard let duration = r.u16(), let amplitude = r.u8() else { return nil }
        self.init(durationMs: duration, amplitude: amplitude)
    }
}

// MARK: - Big-endian helpers

struct ByteWriter {
    private(set) var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v))
    }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
}

/// Every read is bounds-checked and returns nil rather than trapping: bytes
/// come off a socket, and a malformed body must fail the message, not the
/// process.
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u8() -> UInt8? {
        guard offset < data.endIndex else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u16() -> UInt16? {
        guard offset + 2 <= data.endIndex else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    mutating func i16() -> Int16? {
        u16().map { Int16(bitPattern: $0) }
    }
}
