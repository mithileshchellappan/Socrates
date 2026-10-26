import Link

// A remote command's failure in the recorder's own words (DESIGN 9; the phone's screen says the
// same for its own buttons): a short fact as the title, a line only where it tells the student
// something.

extension RemoteProblem {
    var title: String {
        switch action {
        case .resume: String(localized: "Recording couldn’t resume")
        case .pause: String(localized: "Recording couldn’t pause")
        case .nextSlide, .stop: String(localized: "Couldn’t finish")
        }
    }

    var message: String? {
        failure == .inputBusy ? String(localized: "The microphone is in use.") : nil
    }
}
