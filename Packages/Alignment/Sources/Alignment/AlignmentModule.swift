import Foundation
import os

/// Transcript <-> slide alignment: stamps snapped to pauses plus a DP aligner with an off-slide state.
///
/// Entry points: ``SlideAligner/prepare(slides:transcript:duration:glossary:)`` builds a
/// ``PreparedAlignment`` once per lecture (tokenizing, TF-IDF, similarity matrix); its
/// ``PreparedAlignment/align(anchors:)`` runs the constrained Viterbi pass and is cheap enough
/// to re-run on every stamp or manual "slide starts here" edit.
public enum AlignmentModule {
    public static let moduleName = "Alignment"
}

/// Same subsystem and category as `StudyCore.Log.alignment`; this package has no StudyCore dependency.
let alignmentLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "socrates", category: "alignment")
