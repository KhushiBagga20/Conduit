//
//  PhoneScreenView.swift
//  ConduitMedia
//
//  SwiftUI wrapper for the AVSampleBufferDisplayLayer.
//  Mouse and keyboard input capture.
//
//  NSViewRepresentable that hosts a VideoRenderer's display layer
//  inside a SwiftUI layout. The layer maintains aspect ratio via
//  .resizeAspect and automatically tracks the view's bounds.
//
//  The host view is the input surface: it turns AppKit events into
//  calls on InputController, which does the coordinate mapping and
//  speaks the scrcpy control protocol.
//

import SwiftUI
import AVFoundation
import AppKit

// MARK: - SwiftUI Wrapper

/// Displays the phone's mirrored screen and forwards cursor/keyboard
/// input to the device.
public struct PhoneScreenView: NSViewRepresentable {
    let renderer: VideoRenderer
    let input: InputController

    public init(renderer: VideoRenderer, input: InputController) {
        self.renderer = renderer
        self.input = input
    }

    public func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView(displayLayer: renderer.displayLayer)
        view.inputController = input
        return view
    }

    public func updateNSView(_ nsView: VideoHostView, context: Context) {
        // StreamConnection builds a fresh VideoRenderer on every connect,
        // so on reconnect this view may be handed a different layer than
        // the one it was created with. Re-attach if so.
        nsView.setDisplayLayer(renderer.displayLayer)
        nsView.inputController = input
    }
}

// MARK: - NSView Host

/// NSView that hosts an AVSampleBufferDisplayLayer as a sublayer,
/// keeps its frame in sync with the view's bounds, and captures input.
public final class VideoHostView: NSView {

    private var displayLayer: AVSampleBufferDisplayLayer

    /// Owned by MirroringSession; weak here to avoid a retain cycle
    /// through the SwiftUI view tree.
    weak var inputController: InputController?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layer Management

    /// Swap in a new display layer (after a reconnect). No-op if unchanged.
    func setDisplayLayer(_ newLayer: AVSampleBufferDisplayLayer) {
        guard newLayer !== displayLayer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.removeFromSuperlayer()
        displayLayer = newLayer
        newLayer.frame = bounds
        layer?.addSublayer(newLayer)
        CATransaction.commit()
    }

    public override func layout() {
        super.layout()
        // Resize the display layer to fill the view without animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Responder Setup

    public override var acceptsFirstResponder: Bool { true }

    /// Deliver the click that activates the window, instead of swallowing it.
    /// Without this the first tap after focusing the window would be lost.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        NotificationCenter.default.removeObserver(self)

        guard let window = window else { return }
        window.makeFirstResponder(self)

        // If the window loses focus mid-drag, AppKit stops delivering
        // mouseUp. Cancel the gesture so the phone does not think a
        // finger is still pressed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func windowDidResignKey() {
        guard let controller = inputController, controller.isPointerDown else { return }
        controller.cancelGesture(at: lastCursorPoint, in: bounds)
    }

    /// Last known cursor location in view coordinates, used when a gesture
    /// is cancelled without an accompanying event.
    private var lastCursorPoint: CGPoint = .zero

    private func viewPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        lastCursorPoint = point
        return point
    }

    // MARK: - Mouse Input

    public override func mouseDown(with event: NSEvent) {
        inputController?.pointerDown(at: viewPoint(for: event), in: bounds, button: .primary)
    }

    public override func mouseDragged(with event: NSEvent) {
        inputController?.pointerDragged(to: viewPoint(for: event), in: bounds)
    }

    public override func mouseUp(with event: NSEvent) {
        inputController?.pointerUp(at: viewPoint(for: event), in: bounds, button: .primary)
    }

    /// Right-click is BACK — the same mapping scrcpy uses.
    public override func rightMouseDown(with event: NSEvent) {
        _ = viewPoint(for: event)
        inputController?.pressBack()
    }

    public override func rightMouseUp(with event: NSEvent) { /* handled on down */ }

    /// Middle-click is HOME.
    public override func otherMouseDown(with event: NSEvent) {
        _ = viewPoint(for: event)
        inputController?.pressHome()
    }

    public override func otherMouseUp(with event: NSEvent) { /* handled on down */ }

    public override func scrollWheel(with event: NSEvent) {
        let point = viewPoint(for: event)

        // scrcpy's scroll fields are i16 fixed-point over [-1, 1], where
        // 1.0 is roughly one wheel notch. Trackpads report continuous
        // point deltas, so they need a much larger divisor than a wheel.
        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 40 : 3
        let horizontal = Float(clamp(event.scrollingDeltaX / divisor))
        let vertical = Float(clamp(event.scrollingDeltaY / divisor))

        guard horizontal != 0 || vertical != 0 else { return }
        inputController?.scroll(at: point, in: bounds, hScroll: horizontal, vScroll: vertical)
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, -1), 1)
    }

    // MARK: - Keyboard Input

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘V sends the Mac clipboard to the phone and pastes it into
            // the focused field. Everything else ⌘-based stays with AppKit
            // so ⌘Q, ⌘W and friends keep working.
            if event.charactersIgnoringModifiers?.lowercased() == "v" {
                pasteMacClipboardToDevice()
                return
            }
            super.keyDown(with: event)
            return
        }

        if let keycode = Self.androidKeycode(forVirtualKey: event.keyCode) {
            inputController?.pressKey(keycode)
            return
        }

        guard let characters = event.characters, !characters.isEmpty else { return }

        // Drop control characters and AppKit's function-key private-use
        // scalars (F1…, Page Up, …) — they are not text.
        let isTypable = characters.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
        guard isTypable else { return }

        inputController?.typeText(characters)
    }

    /// Swallow key-up so AppKit does not beep at unhandled keys.
    public override func keyUp(with event: NSEvent) { }

    /// Read the Mac pasteboard and hand the text to the device.
    /// Reading NSPasteboard lives here rather than in InputController so
    /// the input layer stays AppKit-free.
    public func pasteMacClipboardToDevice() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.isEmpty else {
            Log.clipboard.info("nothing text-shaped on the pasteboard")
            return
        }
        Log.clipboard.info("sending \(text.count) chars to device")
        inputController?.sendClipboard(text, paste: true)
    }

    /// Map macOS virtual key codes to Android keycodes for the keys that
    /// have no text representation.
    private static func androidKeycode(forVirtualKey keyCode: UInt16) -> AndroidKeycode? {
        switch keyCode {
        case 36, 76:  return .enter       // Return, keypad Enter
        case 51:      return .del         // Delete (backspace)
        case 117:     return .forwardDel  // Forward delete
        case 53:      return .back        // Escape → BACK
        case 48:      return .tab
        case 115:     return .moveHome    // Home
        case 119:     return .moveEnd     // End
        case 123:     return .dpadLeft
        case 124:     return .dpadRight
        case 125:     return .dpadDown
        case 126:     return .dpadUp
        default:      return nil
        }
    }
}
