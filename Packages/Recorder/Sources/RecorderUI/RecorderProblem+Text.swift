import Recorder
import RecorderContract

// The recorder screen's words for a problem (DESIGN 9): a short fact as the title, a line only
// where it tells the student something to do. Live's titles for the same failures at start.

extension RecorderProblem {
    var title: String {
        switch moment {
        case .start:
            switch failure {
            case .microphoneDenied: String(localized: "Microphone access is off")
            case .notConsented: String(localized: "Recording is off for this course")
            case .noInput: String(localized: "No microphone")
            case .inputBusy, .storage, .engine, .stoppedMeanwhile, .unknown: String(localized: "Recording couldn’t start")
            }
        case .recording:
            failure == .notConsented ? String(localized: "Recording is off for this course") : String(localized: "Recording stopped")
        case .command(.resume):
            String(localized: "Recording couldn’t resume")
        case .command(.pause):
            String(localized: "Recording couldn’t pause")
        case .command:
            String(localized: "Couldn’t finish")
        }
    }

    var message: String? {
        failure == .inputBusy ? String(localized: "The microphone is in use.") : nil
    }
}
