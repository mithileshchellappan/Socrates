import SwiftUI

/// The Format menu (DESIGN 6.8, M6): Title, Heading, Subheading, Body; Checklist, Bulleted List,
/// Numbered List; Bold, Italic, Underline, Strikethrough, Highlight; Add Link…. It acts on the
/// note editor that has keyboard focus. Its keys attach only while one has (AppKit lets a
/// disabled item swallow its key); the editor also handles them itself, so they work in every
/// note editor (Notes screen, Review's "Your notes"). The app adds it to its scene.
public struct NoteFormatCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandMenu("Format") {
            NoteFormatMenu()
        }
    }
}

private struct NoteFormatMenu: View {
    var body: some View {
        let editor = NoteEditorFocus.shared.editor
        let keys = editor != nil
        Group {
            ForEach([NoteParagraphKind.title, .heading, .subheading, .body], id: \.self) { kind in
                Button(kind.label) { editor?.apply(kind) }
                    .keyboardShortcut(keys ? kind.shortcut : nil)
            }
            Divider()
            ForEach([NoteParagraphKind.checklist, .bulleted, .numbered], id: \.self) { kind in
                Button(kind.label) { editor?.apply(kind) }
                    .keyboardShortcut(keys ? kind.shortcut : nil)
            }
            Divider()
            ForEach(NoteMark.allCases, id: \.self) { mark in
                Button(mark.label) { editor?.toggle(mark) }
                    .keyboardShortcut(keys ? mark.shortcut : nil)
            }
            Divider()
            Button("Add Link…") { editor?.addLink() }
                .keyboardShortcut(keys ? KeyboardShortcut("k", modifiers: .command) : nil)
        }
        .disabled(editor == nil)
    }
}
