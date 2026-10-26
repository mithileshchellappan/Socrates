import Foundation
import LinkCore
import RecorderContract

/// The Mac's side of one session with a phone: reads the phone's messages in order and answers
/// them. Snapshots and command results go to the service (`PhoneLink`'s state); holdings, offers
/// and chunks to the inbox, one file wanted at a time. A recording whose final offer is whole is
/// moved into `Recordings/`, `received` is said, and the service files it.
struct MacSession {
    let id: UUID
    let device: LinkDeviceID
    let channel: any LinkChannel
    let service: MacLinkService
    let inbox: RecordingInbox
    let controlOn: Bool
    let filesOn: Bool
    /// The one want outstanding.
    private var want: Want?
    private var nextWantID: UInt32 = 0

    private var sender: RecordingInbox.Sender {
        RecordingInbox.Sender(device: device, session: id)
    }

    init(
        id: UUID, device: LinkDeviceID, channel: any LinkChannel, service: MacLinkService, inbox: RecordingInbox,
        controlOn: Bool, filesOn: Bool
    ) {
        self.id = id
        self.device = device
        self.channel = channel
        self.service = service
        self.inbox = inbox
        self.controlOn = controlOn
        self.filesOn = filesOn
    }

    mutating func run() async throws {
        for try await message in channel.messages {
            switch message {
            case .snapshot(let snapshot) where controlOn:
                await service.received(snapshot, session: id)
            case .result(let outcome) where controlOn:
                await service.resolve(outcome)
            case .holdings(let holdings) where filesOn:
                await inbox.keep(holdings.recordings, from: sender)
                // The inbox dropped the recording the want was for (deleted on the phone).
                if let want, !holdings.recordings.contains(want.recording) { self.want = nil }
                try await askNext()
            case .offer(let offer) where filesOn:
                try await take(offer)
            case .chunk(let chunk) where filesOn:
                try await write(chunk)
            default:
                break
            }
        }
    }

    private mutating func take(_ offer: Offer) async throws {
        switch await inbox.offer(offer, from: sender) {
        case .known:
            await service.arrived(offer.recording, at: nil)
            try await channel.send(.received(Received(recording: offer.recording, outcome: .known)), lane: .control)
        case .refused:
            await service.arrived(offer.recording, at: nil)
            try await channel.send(.received(Received(recording: offer.recording, outcome: .refused)), lane: .control)
        case .accepted(let arrival, let held):
            if let arrival { await service.arriving(arrival) }
            for stored in held {
                try await channel.send(.stored(stored), lane: .control)
            }
        }
        try await askNext()
    }

    private mutating func write(_ chunk: Chunk) async throws {
        guard let want, chunk.want == want.id else { return }
        switch await inbox.write(chunk, from: sender) {
        case .written(let stored, let arrival):
            if let arrival { await service.arriving(arrival) }
            if let stored { try await channel.send(.stored(stored), lane: .control) }
        case .verified(let stored, let arrival):
            self.want = nil
            if let arrival { await service.arriving(arrival) }
            try await channel.send(.stored(stored), lane: .control)
            try await askNext()
        case .again:
            self.want = nil
            try await askNext()
        case .refused(let recording):
            self.want = nil
            await service.arrived(recording, at: nil)
            try await channel.send(.received(Received(recording: recording, outcome: .refused)), lane: .control)
            try await askNext()
        case .ignored:
            break
        }
    }

    /// Completes what is whole, then asks for the next missing file, unless a want is out.
    private mutating func askNext() async throws {
        guard want == nil else { return }
        while let recording = await inbox.completeRecording(of: sender) {
            let outcome: Received.Outcome
            var kept: URL?
            switch await inbox.complete(recording, of: sender) {
            case .kept(let url):
                outcome = .kept
                kept = url
            case .known:
                outcome = .known
            case .refused:
                outcome = .refused
            case .failed:
                return
            }
            try await channel.send(.received(Received(recording: recording, outcome: outcome)), lane: .control)
            await service.arrived(recording, at: kept)
        }
        guard let next = await inbox.nextWant(from: sender) else { return }
        nextWantID &+= 1
        let want = Want(id: nextWantID, recording: next.recording, path: next.path, from: next.from)
        self.want = want
        try await channel.send(.want(want), lane: .control)
    }
}
