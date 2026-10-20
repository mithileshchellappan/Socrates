import Foundation
import os

/// Why a translation could not be made.
public enum TranslationError: Error, Sendable, LocalizedError {
    /// No model route between the two languages.
    case unsupportedPair
    /// The volume has less free space than the model download needs.
    case notEnoughSpace
    /// A model file could not be fetched or did not verify.
    case downloadFailed(String)
    /// A downloaded model is missing a file, an input or an output the engine needs.
    case modelUnreadable(String)
    /// ONNX Runtime reported an error.
    case runtime(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPair: "No translation model for this language pair"
        case .notEnoughSpace: "Not enough free space for the translation model"
        case .downloadFailed(let reason): "Model download failed: \(reason)"
        case .modelUnreadable(let reason): "Model unreadable: \(reason)"
        case .runtime(let reason): "ONNX Runtime: \(reason)"
        }
    }
}

enum TranslationLog {
    static let logger = Logger(subsystem: "com.example.studyportal", category: "translation")
}
