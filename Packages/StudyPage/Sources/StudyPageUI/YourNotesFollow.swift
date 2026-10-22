#if os(macOS)
/// What Your notes follows (`YourNotesColumn`): the groups it marks with the quiet fill and scrolls
/// a third down from its top.
public enum YourNotesFollow: Hashable, Sendable {
    /// The notes page's section under its reading line (nil: the overview, nothing marked).
    case section(String?)
    /// Review's slide on screen (nil: none).
    case page(Int?)
}
#endif
