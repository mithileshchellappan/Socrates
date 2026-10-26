import Foundation

/// Bytes of the file a want asked for, at `offset` in that file. The one binary message body:
/// want (UInt32), offset (Int64), both big-endian, then the bytes (at most `LinkPolicy.chunkSize`).
public struct Chunk: Hashable, Sendable {
    /// The `Want.id` this answers.
    public var want: UInt32
    public var offset: Int64
    public var bytes: Data

    public init(want: UInt32, offset: Int64, bytes: Data) {
        self.want = want
        self.offset = offset
        self.bytes = bytes
    }

    /// The fixed fields before the bytes.
    static let headerSize = 12
}
