//
//  InputController.swift
//  ConduitMedia
//
//  Translates Mac cursor/keyboard input into scrcpy control messages.
//
//  Two jobs:
//
//    1. Coordinate mapping. The display layer uses .resizeAspect, so the
//       video sits letterboxed inside the view. A click must be mapped
//       through that letterbox into device pixels, and AppKit's
//       bottom-left origin flipped to Android's top-left.
//
//    2. Gesture state. A touch stream must be well-formed: every DOWN is
//       followed by MOVEs and exactly one UP. Presses that start on the
//       letterbox are ignored; drags that leave the video are clamped to
//       its edge rather than dropped, so a swipe never tears mid-gesture.
//
//  Sends via ControlConnection; reads the live video size from
//  StreamConnection (updated by the session packet on connect and rotation).
//

import Foundation
import CoreGraphics

/// A cursor position resolved into device pixel coordinates, together with
/// the screen size the server should interpret them against.
struct DevicePoint {
    let x: Int32
    let y: Int32
    let screenWidth: UInt16
    let screenHeight: UInt16
}

/// Owns pointer state and converts Mac input events into control messages.
public final class InputController {

    // MARK: - Dependencies

    private let control: ControlConnection
    private let stream: StreamConnection

    init(control: ControlConnection, stream: StreamConnection) {
        self.control = control
        self.stream = stream
    }

    // MARK: - Gesture State

    /// True between a DOWN that landed on the video and its UP.
    /// Guards against emitting MOVE/UP for a press that began on the
    /// letterbox, which would inject a touch the user never made.
    public private(set) var isPointerDown = false

    /// Buttons currently held, as the server should see them.
    private var heldButtons: AndroidButton = []

    // MARK: - Video Geometry

    /// Current decoded video size, or nil before the session packet arrives.
    private var videoSize: CGSize? {
        let w = stream.videoWidth
        let h = stream.videoHeight
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The rect the video actually occupies inside `bounds` under
    /// `.resizeAspect` — i.e. `bounds` minus the letterbox bars.
    ///
    /// Static and pure so the mapping can be reasoned about (and tested)
    /// independently of connection state.
    public static func videoContentRect(videoSize: CGSize, in bounds: CGRect) -> CGRect? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }

        let videoAspect = videoSize.width / videoSize.height
        let boundsAspect = bounds.width / bounds.height

        if boundsAspect > videoAspect {
            // View is wider than the video — bars on the left and right.
            let width = bounds.height * videoAspect
            return CGRect(x: bounds.minX + (bounds.width - width) / 2,
                          y: bounds.minY,
                          width: width,
                          height: bounds.height)
        } else {
            // View is taller than the video — bars on the top and bottom.
            let height = bounds.width / videoAspect
            return CGRect(x: bounds.minX,
                          y: bounds.minY + (bounds.height - height) / 2,
                          width: bounds.width,
                          height: height)
        }
    }

    /// Map a point in AppKit view coordinates to device pixels.
    ///
    /// - Parameter clampToContent: when true, a point outside the video is
    ///   pulled to the nearest edge (used mid-drag, so a swipe that runs off
    ///   the window still tracks). When false, an outside point returns nil
    ///   (used for DOWN, so letterbox clicks are ignored).
    private func devicePoint(
        from viewPoint: CGPoint,
        in bounds: CGRect,
        clampToContent: Bool
    ) -> DevicePoint? {
        guard let size = videoSize,
              let content = Self.videoContentRect(videoSize: size, in: bounds)
        else { return nil }

        // AppKit's origin is bottom-left; Android's is top-left.
        // The content rect is centred, so it is unchanged by the flip.
        let flippedY = bounds.maxY - (viewPoint.y - bounds.minY)

        var relX = (viewPoint.x - content.minX) / content.width
        var relY = (flippedY - content.minY) / content.height

        if clampToContent {
            relX = min(max(relX, 0), 1)
            relY = min(max(relY, 0), 1)
        } else if relX < 0 || relX > 1 || relY < 0 || relY > 1 {
            return nil
        }

        // Convert to pixel indices, keeping the last row/column addressable.
        let maxX = max(Int32(size.width) - 1, 0)
        let maxY = max(Int32(size.height) - 1, 0)
        let x = min(max(Int32(relX * size.width), 0), maxX)
        let y = min(max(Int32(relY * size.height), 0), maxY)

        return DevicePoint(
            x: x,
            y: y,
            screenWidth: UInt16(min(size.width, CGFloat(UInt16.max))),
            screenHeight: UInt16(min(size.height, CGFloat(UInt16.max)))
        )
    }

    // MARK: - Pointer API

    /// Begin a touch. Ignored if the press landed on the letterbox.
    public func pointerDown(at viewPoint: CGPoint, in bounds: CGRect, button: AndroidButton = .primary) {
        // A DOWN while already down means we missed an UP (e.g. the window
        // lost the drag). Cancel the stale gesture before starting a new one.
        if isPointerDown {
            cancelGesture(at: viewPoint, in: bounds)
        }

        guard let point = devicePoint(from: viewPoint, in: bounds, clampToContent: false) else {
            return
        }

        heldButtons.insert(button)
        isPointerDown = true

        sendTouch(action: .down, point: point, pressure: 1.0, actionButton: button)
    }

    /// Continue a touch. Clamped to the video edge so the gesture survives
    /// the cursor leaving the window.
    public func pointerDragged(to viewPoint: CGPoint, in bounds: CGRect) {
        guard isPointerDown,
              let point = devicePoint(from: viewPoint, in: bounds, clampToContent: true)
        else { return }

        sendTouch(action: .move, point: point, pressure: 1.0, actionButton: [])
    }

    /// End a touch.
    public func pointerUp(at viewPoint: CGPoint, in bounds: CGRect, button: AndroidButton = .primary) {
        guard isPointerDown,
              let point = devicePoint(from: viewPoint, in: bounds, clampToContent: true)
        else {
            // Nothing in flight — just make sure we do not keep the button held.
            heldButtons.remove(button)
            return
        }

        // Report the button state as it is *after* the release.
        heldButtons.remove(button)
        isPointerDown = false

        sendTouch(action: .up, point: point, pressure: 0.0, actionButton: button)
    }

    /// Abort an in-flight gesture (window deactivated, disconnect, …).
    public func cancelGesture(at viewPoint: CGPoint, in bounds: CGRect) {
        guard isPointerDown else { return }

        isPointerDown = false
        let released = heldButtons
        heldButtons = []

        guard let point = devicePoint(from: viewPoint, in: bounds, clampToContent: true) else {
            return
        }
        sendTouch(action: .cancel, point: point, pressure: 0.0, actionButton: released)
    }

    /// Drop all gesture state without sending anything.
    /// Used on disconnect, where the socket is already gone.
    func reset() {
        isPointerDown = false
        heldButtons = []
        lastSentClipboard = nil
        isDisplayOn = true
    }

    private func sendTouch(
        action: AndroidMotionAction,
        point: DevicePoint,
        pressure: Float,
        actionButton: AndroidButton
    ) {
        control.send(.injectTouch(
            action: action,
            pointerId: ScrcpyPointerID.mouse,
            x: point.x,
            y: point.y,
            screenWidth: point.screenWidth,
            screenHeight: point.screenHeight,
            pressure: pressure,
            actionButton: actionButton,
            buttons: heldButtons
        ))
    }

    // MARK: - Scroll API

    /// Inject a scroll at the cursor. `hScroll`/`vScroll` are normalised
    /// to [-1, 1] by the caller.
    public func scroll(at viewPoint: CGPoint, in bounds: CGRect, hScroll: Float, vScroll: Float) {
        guard let point = devicePoint(from: viewPoint, in: bounds, clampToContent: false) else {
            return
        }

        control.send(.injectScroll(
            x: point.x,
            y: point.y,
            screenWidth: point.screenWidth,
            screenHeight: point.screenHeight,
            hScroll: hScroll,
            vScroll: vScroll,
            buttons: heldButtons
        ))
    }

    // MARK: - Key & Text API

    /// Press and release a key.
    public func pressKey(_ keycode: AndroidKeycode, metaState: UInt32 = 0) {
        control.send(.injectKeycode(action: .down, keycode: keycode, repeatCount: 0, metaState: metaState))
        control.send(.injectKeycode(action: .up, keycode: keycode, repeatCount: 0, metaState: metaState))
    }

    /// Inject text as if typed.
    public func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        control.send(.injectText(text))
    }

    /// Push text to the device clipboard, optionally pasting it straight
    /// into whatever field has focus.
    ///
    /// Preferred over typeText() for anything non-trivial: INJECT_TEXT is
    /// capped at 300 bytes and is delivered as synthetic keystrokes, which
    /// is slow and mangles characters the device keymap cannot produce.
    /// SET_CLIPBOARD ships the string verbatim in one message.
    ///
    /// The caller supplies the text rather than this type reading
    /// NSPasteboard itself, so the input layer stays free of AppKit.
    public func sendClipboard(_ text: String, paste: Bool = true) {
        guard !text.isEmpty else { return }
        lastSentClipboard = text
        control.send(.setClipboard(sequence: 0, paste: paste, text: text))
    }

    /// The last text pushed to the device.
    ///
    /// clipboard_autosync means the device echoes our own SET_CLIPBOARD
    /// straight back as a device message. Without this, pasting Mac→phone
    /// would immediately rewrite the Mac pasteboard with the same string —
    /// harmless in the simple case, but it clobbers a pasteboard whose
    /// richer types (RTF, images) the round trip has flattened to plain text.
    private(set) var lastSentClipboard: String?

    // MARK: - Navigation

    /// BACK, or wake the device if the screen is off.
    public func pressBack() {
        control.send(.backOrScreenOn(action: .down))
        control.send(.backOrScreenOn(action: .up))
    }

    public func pressHome()    { pressKey(.home) }
    public func pressRecents() { pressKey(.appSwitch) }

    // MARK: - Display Power

    /// Turn the device display off (or back on) without ending the session.
    /// Mirroring and input keep working while it is off — the phone simply
    /// stops lighting its own panel, which saves battery and keeps whatever
    /// you are doing off the physical screen.
    public func setDisplayPower(on: Bool) {
        isDisplayOn = on
        control.send(.setDisplayPower(on: on))
    }

    /// Best-known display state. The device never reports this back, so it
    /// tracks what was last asked for rather than ground truth.
    public private(set) var isDisplayOn = true

    public func toggleDisplayPower() { setDisplayPower(on: !isDisplayOn) }

    /// Rotate the device display.
    public func rotateDevice() {
        control.send(.rotateDevice)
    }
}
