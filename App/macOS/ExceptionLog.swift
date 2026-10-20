import ExceptionHandling
import Foundation
import os

/// Logs the Objective-C exceptions that point at a bug in this app (a bad range or index, an
/// inconsistent state, a bad argument) when they are raised, with their reason and frames, even
/// when AppKit or the text input system catches them itself. The one of 2026-10-20 reached the log
/// only as "HIExceptions FAULT: NSRangeException: <private>", without a reason or a frame. Names,
/// reasons and frames only (an exception's reason never holds the student's text in these cases;
/// it is public so the next one can be read). Nothing is handled differently: the masks only log.
nonisolated final class ExceptionLog: NSObject, Sendable {
    static let shared = ExceptionLog()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "StudyPortal", category: "exceptions")

    /// The exceptions worth a stack: bugs, not a framework's routine control flow.
    private static let names: Set<String> = [
        NSExceptionName.rangeException.rawValue,
        NSExceptionName.internalInconsistencyException.rawValue,
        NSExceptionName.invalidArgumentException.rawValue,
        NSExceptionName.genericException.rawValue,
    ]

    static func install() {
        guard let handler = NSExceptionHandler.default() else { return }
        let mask = NSLogOtherExceptionMask | NSLogTopLevelExceptionMask | NSLogUncaughtExceptionMask
        handler.setExceptionHandlingMask(mask)
        handler.setDelegate(shared)
    }

    override func exceptionHandler(_ sender: NSExceptionHandler!, shouldLogException exception: NSException!, mask aMask: Int) -> Bool {
        guard let exception else { return false }
        let name = exception.name.rawValue
        guard Self.names.contains(name) else { return false }
        let reason = exception.reason ?? ""
        let frames = exception.callStackSymbols.prefix(40).joined(separator: "\n")
        logger.fault("\(name, privacy: .public): \(reason, privacy: .public)\n\(frames, privacy: .public)")
        return false
    }
}
