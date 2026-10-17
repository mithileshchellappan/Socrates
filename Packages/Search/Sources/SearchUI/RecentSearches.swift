import Foundation
import StudyUI
import SwiftUI

/// The last few searches, newest first, distinct ignoring case: what the sidebar lists under
/// "Recent searches" while Search is open (mockup 07).
///
/// Kept in the app's defaults under `storageKey` as a JSON array of strings (`@AppStorage`). The
/// search screen records its query when ↩ in the search field opens a hit and when a hit is opened.
public struct RecentSearches: Equatable, Sendable {
    public static let storageKey = "recentSearches"
    /// How many the sidebar shows.
    public static let limit = 3

    /// Newest first.
    public private(set) var queries: [String] = []

    public init(_ queries: [String] = []) {
        for query in queries.reversed() { record(query) }
    }

    /// Reads the stored JSON array; anything else reads as none.
    public init(storage: String) {
        let stored = (try? JSONDecoder().decode([String].self, from: Data(storage.utf8))) ?? []
        self.init(stored)
    }

    /// The JSON array to store.
    public var storage: String {
        guard let data = try? JSONEncoder().encode(queries) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Puts `query` (whitespace collapsed) first, dropping an earlier search that differs only in
    /// case and the oldest beyond `limit`. A blank query is ignored.
    public mutating func record(_ query: String) {
        let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return }
        queries.removeAll { $0.compare(text, options: .caseInsensitive) == .orderedSame }
        queries.insert(text, at: 0)
        if queries.count > Self.limit { queries.removeLast(queries.count - Self.limit) }
    }
}

/// The sidebar's "Recent searches" section (mockup 07): one row per recent query, a clock glyph in
/// secondary grey. Choosing one searches for it again (`StudyDestination.search`). Nothing while
/// there are none.
///
/// For the sidebar's `List`, under Courses, only while Search is selected (mockup 01 Today has none).
public struct RecentSearchesSection: View {
    @AppStorage(RecentSearches.storageKey) private var storage = ""
    @Environment(\.openDestination) private var openDestination

    public init() {}

    public var body: some View {
        let recent = RecentSearches(storage: storage).queries
        if !recent.isEmpty {
            Section {
                ForEach(recent, id: \.self) { query in
                    Button {
                        openDestination(.search(query))
                    } label: {
                        SidebarRowLabel(query) {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SidebarSectionTitle("Recent searches")
            }
        }
    }
}
