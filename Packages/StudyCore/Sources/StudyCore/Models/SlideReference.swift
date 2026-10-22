import Foundation

/// The deck page a fact was read from (a `slide` source): "<deck id>:<page>" in
/// `ItemFinding.Source.external(.slide, reference:)`, so in `tracked_item_source.rfc_message_id`
/// and `agent_change.rfc_message_id`.
public struct SlideReference: Hashable, Sendable {
    public var deckID: Deck.ID
    /// 1-based.
    public var page: Int

    public init(deckID: Deck.ID, page: Int) {
        self.deckID = deckID
        self.page = page
    }

    /// Nil when `reference` is not "<deck id>:<page>".
    public init?(_ reference: String) {
        let parts = reference.split(separator: ":")
        guard parts.count == 2, let deckID = UUID(uuidString: String(parts[0])), let page = Int(parts[1]), page > 0 else { return nil }
        self.init(deckID: deckID, page: page)
    }

    public var reference: String { "\(deckID.uuidString.lowercased()):\(page)" }
}
