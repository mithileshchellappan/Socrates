import Foundation

/// One request to the iPhone recorder, from any surface: the recorder screen, the Live Activity
/// (across the app–extension boundary) and later the Mac remote. Every surface sends these and
/// nothing else; the recorder validates each against its current state and applies an id once.
public struct RecorderCommand: Codable, Hashable, Sendable, Identifiable {
    /// The idempotency key. Every delivery of one request carries the same id (a retried send, an
    /// intent the system runs twice), and the recorder applies an id at most once.
    public struct ID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }
    }

    /// What to do.
    public enum Action: Codable, Hashable, Sendable {
        /// The input goes off and the audio written so far is closed; nothing is captured until
        /// `resume`.
        case pause
        /// Records again into the same recording, after the real time paused.
        case resume
        /// Stamps the next slide. `from` is the slide the surface showed: the recorder moves only
        /// while it is still on it, so a stale or repeated button never skips a slide. Nil (the
        /// recorder's own screen, in process) moves from wherever it is.
        case nextSlide(from: Int?)
        /// Stamps the previous slide; `from` as for `nextSlide`.
        case previousSlide(from: Int?)
        /// Flags this moment.
        case flag
        /// Stops recording; the package is final.
        case stop

        public var kind: Kind {
            switch self {
            case .pause: .pause
            case .resume: .resume
            case .nextSlide: .nextSlide
            case .previousSlide: .previousSlide
            case .flag: .flag
            case .stop: .stop
            }
        }

        /// The slide the surface showed, for the slide moves that carry one.
        public var shownSlide: Int? {
            switch self {
            case .nextSlide(let from), .previousSlide(let from): from
            case .pause, .resume, .flag, .stop: nil
            }
        }
    }

    /// An action without its arguments: what a snapshot says the recorder accepts now.
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case pause, resume, nextSlide, previousSlide, flag, stop

        /// The kinds among `rawValues` this build knows; a newer sender's unknown kinds are
        /// dropped, so its snapshot still decodes (`RecorderSnapshot.accepts`).
        public static func known(_ rawValues: [String]) -> Set<Kind> {
            Set(rawValues.compactMap(Kind.init(rawValue:)))
        }
    }

    /// Where a command came from. Logged, and it changes one thing: a Live Activity command
    /// returns only once the activity shows its outcome (the app may be suspended right after an
    /// intent returns), and one that did nothing redraws the activity from the current state.
    public enum Origin: String, Codable, Hashable, Sendable {
        case screen, liveActivity, remote
    }

    public var id: ID
    /// The recording it is for: a command for another recording never acts.
    public var recordingID: RecordingID
    public var action: Action
    public var origin: Origin

    public init(id: ID, recordingID: RecordingID, action: Action, origin: Origin) {
        self.id = id
        self.recordingID = recordingID
        self.action = action
        self.origin = origin
    }

    /// A new request with a new id: one tap on the screen, one remote button press. A retry of
    /// the same request reuses the command (and so its id).
    public static func fresh(_ action: Action, recordingID: RecordingID, origin: Origin) -> Self {
        Self(id: ID(rawValue: UUID().uuidString), recordingID: recordingID, action: action, origin: origin)
    }

    /// A Live Activity button's request: the id is derived from what the button was drawn for
    /// (`<recording>/<snapshot sequence>/<kind>`), so every run of one tap, and every tap on one
    /// rendering, is the same request and acts once.
    public static func rendered(_ action: Action, recordingID: RecordingID, sequence: Int) -> Self {
        Self(
            id: ID(rawValue: "\(recordingID.uuidString)/\(sequence)/\(action.kind.rawValue)"),
            recordingID: recordingID,
            action: action,
            origin: .liveActivity
        )
    }
}
