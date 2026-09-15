//
//  Log.swift
//  ConduitMedia
//
//  Structured logging for the scrcpy client.
//
//  Messages are logged as public so they are readable in Console, which is
//  why nothing personal is ever put into one: clipboard text is reported by
//  length only, and identifying values (device names) go through
//  `infoRedacted`, which the system redacts outside a debugging session.
//
//  Read with:
//    log stream --level debug --predicate 'subsystem == "com.khushi.Conduit"'
//

import OSLog

nonisolated struct MediaLogger: Sendable {
    let logger: Logger

    init(_ category: String) {
        logger = Logger(subsystem: "com.khushi.Conduit", category: category)
    }

    func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    func error(_ message: String) { logger.error("\(message, privacy: .public)") }

    /// For values that identify a person or their device.
    func infoRedacted(_ label: String, _ value: String) {
        logger.info("\(label, privacy: .public): \(value, privacy: .private)")
    }
}

nonisolated enum Log {
    static let session = MediaLogger("mirroring")
    static let video = MediaLogger("video")
    static let wire = MediaLogger("scrcpy-protocol")
    static let control = MediaLogger("control")
    static let audio = MediaLogger("audio")
    static let decoder = MediaLogger("decoder")
    static let renderer = MediaLogger("renderer")
    static let clipboard = MediaLogger("clipboard")
}
