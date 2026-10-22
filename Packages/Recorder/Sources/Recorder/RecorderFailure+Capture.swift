import Capture
import RecorderContract

// Capture's errors become the contract's typed failures here, once: every surface and the coming
// Mac remote see `RecorderFailure`, never a system error string.

extension RecorderFailure {
    /// What a capture or session error means for the recorder.
    init(_ error: any Error) {
        if let failure = error as? LiveLectureSession.Failure {
            self.init(failure)
            return
        }
        switch error as? CaptureError {
        case .inputBusy?: self = .inputBusy
        case .microphoneDenied?: self = .microphoneDenied
        case .noInputDevice?: self = .noInput
        case .writeFailed?: self = .storage
        case .engineFailed?: self = .engine
        case .notRecording?, .notPaused?, .alreadyRecording?: self = .stoppedMeanwhile
        case nil: self = .engine
        }
    }

    /// Why a session failed (to start, or while recording).
    init(_ failure: LiveLectureSession.Failure) {
        switch failure {
        case .notConsented: self = .notConsented
        case .microphoneDenied: self = .microphoneDenied
        case .noInputDevice: self = .noInput
        case .inputBusy: self = .inputBusy
        case .storage: self = .storage
        case .engine: self = .engine
        }
    }
}
