import NotesUI
import Review
import StudyCore
import StudyPageUI
import SwiftUI

/// A chip in a note of this lecture moves the review (the slide, or playback from the moment);
/// one of another lecture opens that lecture.
@MainActor
enum ReviewNoteLinks {
    #if os(macOS)
    /// ln: a chip in the lecture's notes, the same way.
    static func open(_ target: NotesChipTarget, model: ReviewModel) -> Bool {
        switch target {
        case .slide(let lecture, let page):
            return open(.slide(SourceRef(kind: .slide, lectureID: lecture, pageNumber: page)), model: model)
        case .moment(let lecture, let recording, let seconds):
            // A chip without a recording key is on the lecture's first recording.
            let recording = recording ?? (lecture == model.lecture.id ? model.recordings.first?.id : nil)
            return open(.time(SourceRef(kind: .transcript, lectureID: lecture, recordingID: recording, time: seconds)), model: model)
        case .material:
            // mt: a book chip opens the reader (the notes' own handling).
            return false
        }
    }
    #endif

    static func open(_ link: NoteLink, model: ReviewModel) -> Bool {
        switch link {
        case .slide(let source):
            guard (source.lectureID ?? model.lecture.id) == model.lecture.id, let page = source.pageNumber,
                  source.deckID == nil || source.deckID == model.deckID, model.deck != nil, model.shows(page: page)
            else { return false }
            Task { await model.session.selectThumbnail(page: page) }
            return true
        case .time(let source):
            // On the recording on screen, or on another of the lecture's (that one loads there).
            guard (source.lectureID ?? model.lecture.id) == model.lecture.id, let time = source.time, model.player != nil,
                  source.recordingID.map({ id in model.recordings.contains { $0.id == id } }) ?? true
            else { return false }
            model.play(from: time, on: source.recordingID)
            return true
        }
    }
}
