import Foundation
import RecorderContract

/// How a message travels: a 5-byte header, `[kind UInt8][length UInt32 big-endian]`, then the
/// body. The reader takes the header first (`receive(exactly: headerSize)`), checks the length
/// against `maximumBody` before reading a single body byte, then reads exactly that many.
///
/// Bodies are JSON with the encoder's and decoder's defaults on both sides (later fields
/// optional); the one binary body is a chunk's (`Chunk`).
public enum LinkFrame {
    public static let headerSize = 5
    /// The largest body: a full chunk and its fixed fields, with room to spare. One cap for every
    /// kind.
    public static let maximumBody = 256 * 1024 + 16

    /// The whole frame (header and body) for `message`.
    public static func encode(_ message: LinkMessage) throws(LinkProtocolError) -> Data {
        let kind = message.kind
        let body: Data
        switch message {
        case .hello(let hello): body = try json(hello, kind: kind)
        case .goodbye(let goodbye): body = try json(goodbye, kind: kind)
        case .ping(let ping), .pong(let ping): body = try json(ping, kind: kind)
        case .snapshot(let snapshot): body = try json(snapshot, kind: kind)
        case .command(let command): body = try json(command, kind: kind)
        case .result(let outcome): body = try json(outcome, kind: kind)
        case .holdings(let holdings): body = try json(holdings, kind: kind)
        case .offer(let offer): body = try json(offer, kind: kind)
        case .want(let want): body = try json(want, kind: kind)
        case .stored(let stored): body = try json(stored, kind: kind)
        case .received(let received): body = try json(received, kind: kind)
        case .chunk(let chunk):
            guard chunk.offset >= 0 else { throw .unexpected(kind: kind) }
            var data = Data(capacity: Chunk.headerSize + chunk.bytes.count)
            data.appendBigEndian(chunk.want)
            data.appendBigEndian(UInt64(bitPattern: chunk.offset))
            data.append(chunk.bytes)
            body = data
        case .unknown:
            throw .unexpected(kind: kind)
        }
        guard body.count <= maximumBody else { throw .oversized(kind: kind, length: body.count) }
        var frame = Data(capacity: headerSize + body.count)
        frame.append(kind)
        frame.appendBigEndian(UInt32(body.count))
        frame.append(body)
        return frame
    }

    /// The kind and body length a header announces; a length over `maximumBody` is refused here,
    /// before the body is read.
    public static func header(_ bytes: Data) throws(LinkProtocolError) -> (kind: UInt8, length: Int) {
        guard bytes.count == headerSize, let kind = bytes.first else {
            throw .malformed(kind: bytes.first ?? 0)
        }
        let length = Int(bytes.bigEndian(UInt32.self, at: 1))
        guard length <= maximumBody else { throw .oversized(kind: kind, length: length) }
        return (kind, length)
    }

    /// The message a body of `kind` holds; a kind this build does not know is `.unknown`.
    public static func decode(kind: UInt8, body: Data) throws(LinkProtocolError) -> LinkMessage {
        guard body.count <= maximumBody else { throw .oversized(kind: kind, length: body.count) }
        switch kind {
        case LinkMessage.Kind.hello: return .hello(try value(Hello.self, from: body, kind: kind))
        case LinkMessage.Kind.goodbye: return .goodbye(try value(Goodbye.self, from: body, kind: kind))
        case LinkMessage.Kind.ping: return .ping(try value(Ping.self, from: body, kind: kind))
        case LinkMessage.Kind.pong: return .pong(try value(Ping.self, from: body, kind: kind))
        case LinkMessage.Kind.snapshot: return .snapshot(try value(SnapshotMessage.self, from: body, kind: kind))
        case LinkMessage.Kind.command: return .command(try value(RecorderCommand.self, from: body, kind: kind))
        case LinkMessage.Kind.result: return .result(try value(RecorderOutcome.self, from: body, kind: kind))
        case LinkMessage.Kind.holdings: return .holdings(try value(Holdings.self, from: body, kind: kind))
        case LinkMessage.Kind.offer: return .offer(try value(Offer.self, from: body, kind: kind))
        case LinkMessage.Kind.want: return .want(try value(Want.self, from: body, kind: kind))
        case LinkMessage.Kind.stored: return .stored(try value(Stored.self, from: body, kind: kind))
        case LinkMessage.Kind.received: return .received(try value(Received.self, from: body, kind: kind))
        case LinkMessage.Kind.chunk:
            guard body.count >= Chunk.headerSize else { throw .malformed(kind: kind) }
            let want = body.bigEndian(UInt32.self, at: 0)
            let offset = Int64(bitPattern: body.bigEndian(UInt64.self, at: 4))
            guard offset >= 0 else { throw .malformed(kind: kind) }
            return .chunk(Chunk(want: want, offset: offset, bytes: Data(body.dropFirst(Chunk.headerSize))))
        default:
            return .unknown(kind: kind)
        }
    }

    private static func json(_ message: some Encodable, kind: UInt8) throws(LinkProtocolError) -> Data {
        do {
            return try JSONEncoder().encode(message)
        } catch {
            throw .malformed(kind: kind)
        }
    }

    private static func value<Message: Decodable>(
        _ type: Message.Type, from body: Data, kind: UInt8
    ) throws(LinkProtocolError) -> Message {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw .malformed(kind: kind)
        }
    }
}

extension Data {
    fileprivate mutating func appendBigEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// The unsigned integer stored big-endian at `offset` from the start (the caller checked the
    /// length).
    fileprivate func bigEndian<Value: FixedWidthInteger & UnsignedInteger>(_ type: Value.Type, at offset: Int) -> Value {
        let start = startIndex + offset
        return self[start..<(start + MemoryLayout<Value>.size)].reduce(0) { $0 << 8 | Value($1) }
    }
}
