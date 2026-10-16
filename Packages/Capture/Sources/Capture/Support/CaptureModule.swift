import StudyCore
import os

/// Live lecture capture: lecture packages on disk, segmented recording, slide stamps on the
/// audio clock, slide deck rendering, live captions, and import of finished packages into the
/// database.
public enum CaptureModule {
    public static let moduleName = "Capture"
}

enum CaptureLog {
    static let capture = Log.capture
    static let deck = Log.logger(category: "capture.deck")
    static let captions = Log.logger(category: "capture.captions")
}
