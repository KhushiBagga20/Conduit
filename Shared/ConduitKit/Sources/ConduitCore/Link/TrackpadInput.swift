//
//  TrackpadInput.swift
//  ConduitCore
//
//  Turns the phone's trackpad into this Mac's pointer — Shared/Protocol
//  README.md §7, channel `input`.
//
//  Posting events is exactly what macOS Accessibility permission governs, so
//  nothing here works until the person grants it; Conduit says so rather
//  than moving nothing and staying silent.
//

import AppKit
import ApplicationServices
import ConduitMedia
import ConduitProtocol
import CoreGraphics

@MainActor
final class TrackpadInput {

    /// Whether macOS lets Conduit post pointer events at all.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility permission, which shows its own prompt
    /// the first time and adds Conduit to the list in System Settings.
    static func requestTrust() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// How far the pointer travels per point of finger movement, before the
    /// acceleration below.
    var sensitivity: Double = 1.6
    /// Content follows the fingers, as macOS does by default.
    var naturalScrolling = true

    private var buttonsDown: Set<PointerButton> = []
    private var lastClick: (button: PointerButton, at: Date, count: Int64) = (.left, .distantPast, 0)

    func handle(_ event: InputEvent) {
        switch event {
        case let .move(dx, dy):
            move(dx: Double(dx), dy: Double(dy))
        case let .button(button, down):
            click(button, down: down)
        case let .scroll(dx, dy):
            scroll(dx: Double(dx), dy: Double(dy))
        case .key:
            // The layout is in the spec; nothing sends these yet.
            CoreLog.engine.debug("ignoring a key from the phone's trackpad")
        }
    }

    /// Lets go of anything the phone was holding — when it disconnects, or
    /// when the person turns the trackpad off. A button left down would
    /// otherwise stay down with nothing to release it.
    func releaseEverything() {
        for button in buttonsDown { post(button, down: false) }
        buttonsDown.removeAll()
    }

    // MARK: - Pointer

    private func move(dx: Double, dy: Double) {
        // A gentle curve, as trackpads have: slow movement is precise, fast
        // movement crosses the screen.
        let speed = (dx * dx + dy * dy).squareRoot()
        let boost = min(1 + speed / 24, 2.5)
        let step = sensitivity * boost

        let from = currentLocation
        let to = clampToScreens(CGPoint(x: from.x + dx * step, y: from.y + dy * step))

        let type: CGEventType = buttonsDown.contains(.left) ? .leftMouseDragged
            : buttonsDown.contains(.right) ? .rightMouseDragged
            : buttonsDown.contains(.middle) ? .otherMouseDragged : .mouseMoved
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: to,
                                  mouseButton: cgButton(buttonsDown.first ?? .left)) else { return }
        // Apps that read deltas (games, drawing) need them; the difference in
        // positions is not enough after clamping.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((to.x - from.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((to.y - from.y).rounded()))
        event.post(tap: .cghidEventTap)
    }

    private func click(_ button: PointerButton, down: Bool) {
        if down { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        post(button, down: down)
    }

    private func post(_ button: PointerButton, down: Bool) {
        let type: CGEventType
        switch (button, down) {
        case (.left, true): type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.middle, true): type = .otherMouseDown
        case (.middle, false): type = .otherMouseUp
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: currentLocation, mouseButton: cgButton(button))
        else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState(for: button, down: down))
        event.post(tap: .cghidEventTap)
    }

    /// Double and triple clicks are not timing the Mac works out for injected
    /// events: the click count has to be counted here and sent with them.
    private func clickState(for button: PointerButton, down: Bool) -> Int64 {
        guard down else { return max(lastClick.count, 1) }
        let now = Date()
        let interval = NSEvent.doubleClickInterval
        let continues = button == lastClick.button && now.timeIntervalSince(lastClick.at) <= interval
        let count = continues ? min(lastClick.count + 1, 3) : 1
        lastClick = (button, now, count)
        return count
    }

    private func scroll(dx: Double, dy: Double) {
        let direction: Double = naturalScrolling ? 1 : -1
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32((dy * direction).rounded()),
                                  wheel2: Int32((dx * direction).rounded()), wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Geometry

    private var currentLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Keeps the pointer on a screen. Event coordinates have their origin at
    /// the top left of the main display, which is what `CGDisplayBounds` uses.
    private func clampToScreens(_ point: CGPoint) -> CGPoint {
        let screens = NSScreen.screens.map { screen -> CGRect in
            guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else { return .zero }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }.filter { !$0.isEmpty }

        if let inside = screens.first(where: { $0.contains(point) }) {
            return CGPoint(x: min(max(point.x, inside.minX), inside.maxX - 1),
                           y: min(max(point.y, inside.minY), inside.maxY - 1))
        }
        // Between or beyond screens: stay on the nearest one.
        guard let nearest = screens.min(by: { distance($0, point) < distance($1, point) }) else { return point }
        return CGPoint(x: min(max(point.x, nearest.minX), nearest.maxX - 1),
                       y: min(max(point.y, nearest.minY), nearest.maxY - 1))
    }

    private func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let x = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let y = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return x * x + y * y
    }

    private func cgButton(_ button: PointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }
}
