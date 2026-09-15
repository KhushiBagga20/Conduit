//
//  Log.swift
//  ConduitMedia
//
//  Structured logging for Conduit on the Mac.
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

/// Shared with ConduitCore through `package` access.
package nonisolated struct ConduitLogger: Sendable {
    let logger: Logger

    package init(_ category: String) {
        logger = Logger(subsystem: "com.khushi.Conduit", category: category)
    }

    package func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    package func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    package func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    package func error(_ message: String) { logger.error("\(message, privacy: .public)") }

    /// For values that identify a person or their device.
    package func infoRedacted(_ label: String, _ value: String) {
        logger.info("\(label, privacy: .public): \(value, privacy: .private)")
    }
}

nonisolated enum Log {
    static let session = ConduitLogger("mirroring")
    static let video = ConduitLogger("video")
    static let wire = ConduitLogger("scrcpy-protocol")
    static let control = ConduitLogger("control")
    static let audio = ConduitLogger("audio")
    static let decoder = ConduitLogger("decoder")
    static let renderer = ConduitLogger("renderer")
    static let clipboard = ConduitLogger("clipboard")
}
