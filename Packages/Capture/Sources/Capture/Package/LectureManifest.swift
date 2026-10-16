import Foundation

/// One audio file of a recording, placed on the recording clock by `startSample`.
///
/// Segments are contiguous on the clock unless the input was reconfigured (device change,
/// interruption); then the next segment starts where real time had got to, leaving a gap that
/// players and transcribers must fill with silence.
public struct AudioSegmentInfo: Codable, Sendable, Hashable, Identifiable {
    public enum StartReason: String, Codable, Sendable, Hashable {
        /// First segment of the recording.
        case start
        /// The previous segment reached its maximum length.
        case rollover
        /// The input was reconfigured (device change, interruption, engine restart).
        case discontinuity
    }

    public var id: UUID
    /// 1-based; matches the file name (`seg-0001.caf`).
    public var sequence: Int
    /// Path relative to the package root, e.g. `audio/seg-0001.caf`.
    public var file: String
    /// Frame offset of the file's first sample on the recording clock.
    public var startSample: Int64
    /// Frames in the file; nil while the segment is being written (or after a crash).
    public var frameCount: Int64?
    /// `mach_absolute_time()` of the first frame, when known.
    public var hostTime: UInt64?
    public var startReason: StartReason
    /// Input device name, when known.
    public var device: String?

    public init(
        id: UUID = UUID(),
        sequence: Int,
        file: String,
        startSample: Int64,
        frameCount: Int64? = nil,
        hostTime: UInt64? = nil,
        startReason: StartReason,
        device: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.file = file
        self.startSample = startSample
        self.frameCount = frameCount
        self.hostTime = hostTime
        self.startReason = startReason
        self.device = device
    }

    /// First frame after this segment on the recording clock (nil while open).
    public var endSample: Int64? {
        frameCount.map { startSample + $0 }
    }
}

/// The input device a recording started on.
public struct AudioDeviceInfo: Codable, Sendable, Hashable {
    public var name: String
    /// CoreAudio device UID (macOS) or port UID (iOS).
    public var uid: String?
    /// Native sample rate of the device when recording started.
    public var nativeSampleRate: Double?
    public var nativeChannelCount: Int?

    public init(name: String, uid: String? = nil, nativeSampleRate: Double? = nil, nativeChannelCount: Int? = nil) {
        self.name = name
        self.uid = uid
        self.nativeSampleRate = nativeSampleRate
        self.nativeChannelCount = nativeChannelCount
    }
}

/// The slide deck shown during the lecture.
public struct DeckReference: Codable, Sendable, Hashable {
    /// Lowercase hex SHA-256 of the PDF (matches `Deck.blobSHA256`).
    public var sha256: String
    public var pageCount: Int
    public var title: String?
    /// `Deck.id` in the database, when the deck was already imported.
    public var deckID: UUID?

    public init(sha256: String, pageCount: Int, title: String? = nil, deckID: UUID? = nil) {
        self.sha256 = sha256
        self.pageCount = pageCount
        self.title = title
        self.deckID = deckID
    }
}

/// Contents of `manifest.json`.
public struct LectureManifest: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    /// The package id; also used as `Recording.id` on import.
    public var id: UUID
    public var courseID: UUID?
    public var lectureID: UUID?
    public var deck: DeckReference?
    /// Wall clock at sample 0 (nil until audio arrived).
    public var startedAt: Date?
    /// `mach_absolute_time()` at sample 0.
    public var hostTimeAtStart: UInt64?
    /// Set when recording stopped cleanly; nil after a crash.
    public var endedAt: Date?
    public var sampleRate: Double
    public var channelCount: Int
    /// Container of the audio files, e.g. "caf".
    public var fileFormat: String
    public var device: AudioDeviceInfo?
    /// "macOS", "iPadOS" or "iOS".
    public var platform: String
    /// BCP 47 locale of the live captions, if any ran.
    public var captionLocale: String?
    public var segments: [AudioSegmentInfo]
    /// Set once the package was imported into the database.
    public var importedAt: Date?

    public init(
        version: Int = LectureManifest.currentVersion,
        id: UUID,
        courseID: UUID? = nil,
        lectureID: UUID? = nil,
        deck: DeckReference? = nil,
        startedAt: Date? = nil,
        hostTimeAtStart: UInt64? = nil,
        endedAt: Date? = nil,
        format: RecordingFormat = .standard,
        device: AudioDeviceInfo? = nil,
        platform: String = LectureManifest.currentPlatform,
        captionLocale: String? = nil,
        segments: [AudioSegmentInfo] = [],
        importedAt: Date? = nil
    ) {
        self.version = version
        self.id = id
        self.courseID = courseID
        self.lectureID = lectureID
        self.deck = deck
        self.startedAt = startedAt
        self.hostTimeAtStart = hostTimeAtStart
        self.endedAt = endedAt
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.fileFormat = format.fileExtension
        self.device = device
        self.platform = platform
        self.captionLocale = captionLocale
        self.segments = segments
        self.importedAt = importedAt
    }

    public static var currentPlatform: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac ? "macOS" : (isPad ? "iPadOS" : "iOS")
        #else
        "unknown"
        #endif
    }

    #if os(iOS)
    private static var isPad: Bool {
        // UIDevice is UIKit; the model identifier is enough here.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated.hasPrefix("iPad")
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.hasPrefix("iPad")
    }
    #endif
}
