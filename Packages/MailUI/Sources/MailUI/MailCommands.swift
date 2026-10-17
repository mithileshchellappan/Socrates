import StudyCore
import SwiftUI

/// What the Mail screen in the key window can do right now, published as a focused scene value
/// for `MailCommands`.
@MainActor
struct MailScreenCommands {
    var canCompose: Bool
    var canReply: Bool
    var canArchive: Bool
    var hasSelection: Bool
    var isFlagged: Bool
    var isUnread: Bool
    /// The selected message is in another language than the student's.
    var canTranslate: Bool
    /// The selected message is shown translated.
    var isTranslated: Bool
    /// A text field of the screen (the editor, the window's search field) has focus.
    var isEditingText: Bool

    var newMessage: () -> Void
    var getMail: () -> Void
    var reply: () -> Void
    var archive: () -> Void
    var toggleFlag: () -> Void
    var toggleSeen: () -> Void
    var toggleTranslation: () -> Void
}

extension FocusedValues {
    /// The Mail screen in the key window, if any.
    @Entry var mailScreen: MailScreenCommands?
}

/// The Message menu: New Message, Get Mail, Reply (⌘R), Send (⇧⌘D, from the composer only),
/// Archive (⌃⌘A), Flag (⇧⌘L), Mark as Read/Unread (⇧⌘U), Translate / Show Original (⌃⌘T, only
/// for a message in another language than the student's).
///
/// A menu item takes its key equivalent even while disabled (docs/decisions.md), so the keys are
/// attached only while the Mail screen is in the key window (Send only while a composer is on
/// screen); Reply, Archive, Flag, Mark and Translate are off while text is being typed. New
/// Message and Get Mail have no keys: ⌘N is File ▸ New Window and ⇧⌘N New Lecture Capture.
///
///     WindowGroup { … }.commands { MailCommands() }
public struct MailCommands: Commands {
    @FocusedValue(\.mailScreen) private var mail
    @FocusedValue(\.mailComposer) private var composer

    public init() {}

    public var body: some Commands {
        let keys = mail != nil
        let editing = mail?.isEditingText == true
        CommandMenu("Message") {
            Button("New Message") { mail?.newMessage() }
                .disabled(mail?.canCompose != true)
            Button("Get Mail") { mail?.getMail() }
                .disabled(mail == nil)
            Divider()
            Button("Reply") { mail?.reply() }
                .keyboardShortcut(keys ? KeyboardShortcut("r", modifiers: [.command]) : nil)
                .disabled(mail?.canReply != true || editing)
            Button("Send") { composer?.send() }
                .keyboardShortcut(keys && composer != nil ? KeyboardShortcut("d", modifiers: [.command, .shift]) : nil)
                .disabled(composer?.canSend != true)
            Divider()
            Button("Archive") { mail?.archive() }
                .keyboardShortcut(keys ? KeyboardShortcut("a", modifiers: [.command, .control]) : nil)
                .disabled(mail?.canArchive != true || editing)
            Button(mail?.isFlagged == true ? "Unflag" : "Flag") { mail?.toggleFlag() }
                .keyboardShortcut(keys ? KeyboardShortcut("l", modifiers: [.command, .shift]) : nil)
                .disabled(mail?.hasSelection != true || editing)
            Button(mail?.isUnread == true ? "Mark as Read" : "Mark as Unread") { mail?.toggleSeen() }
                .keyboardShortcut(keys ? KeyboardShortcut("u", modifiers: [.command, .shift]) : nil)
                .disabled(mail?.hasSelection != true || editing)
            Divider()
            Button(mail?.isTranslated == true ? "Show Original" : "Translate") { mail?.toggleTranslation() }
                .keyboardShortcut(keys ? KeyboardShortcut("t", modifiers: [.command, .control]) : nil)
                .disabled(mail?.canTranslate != true || editing)
        }
    }
}
