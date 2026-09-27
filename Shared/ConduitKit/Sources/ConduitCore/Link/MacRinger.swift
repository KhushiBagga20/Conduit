//
//  MacRinger.swift
//  ConduitCore
//
//  Makes this Mac findable by ear when the phone asks — Shared/Protocol
//  README.md §6, `mac.find`.
//
//  It plays at this Mac's own volume: Conduit does not touch the system
//  volume behind the person's back, so the interfaces say so plainly and the
//  ringing window is what finds a muted Mac.
//

import AppKit
import ConduitMedia
import Foundation

@MainActor
final class MacRinger {

    /// Ringing stops by itself after this long, in case nobody is at the Mac.
    static let maximumSeconds: Double = 120

    private var sound: NSSound?
    private var deadline: DispatchWorkItem?

    var isRinging: Bool { sound != nil || deadline != nil }

    /// Rings until `stop()`, or until the deadline — which calls `ranOut`.
    func start(ranOut: @escaping () -> Void) {
        stop()

        // A system alert sound: on every Mac, and made to be noticed.
        if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Submarine.aiff", byReference: true) {
            sound.loops = true
            sound.volume = 1
            sound.play()
            self.sound = sound
        } else {
            CoreLog.engine.error("this Mac has no alert sound to ring with; ringing on screen only")
        }

        let deadline = DispatchWorkItem { [weak self] in
            self?.stop()
            ranOut()
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maximumSeconds, execute: deadline)
    }

    func stop() {
        sound?.stop()
        sound = nil
        deadline?.cancel()
        deadline = nil
    }
}
