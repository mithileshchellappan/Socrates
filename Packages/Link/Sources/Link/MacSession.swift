import Foundation
import LinkCore
import RecorderContract

/// The Mac's side of one session with a phone: reads the phone's messages in order and answers
/// them. Snapshots and command results go to the service (`PhoneLink`'s state); holdings, offers
/// and chunks to the inbox, one file wanted at a time. A recording whose final offer is whole is
/// moved into `Recordings/`, the service files it, and `received` is said. One that cannot be
/// moved waits for the next session without holding up the phone's other files.
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
    /// Whole recordings that could not be completed in this session (tried again in the next).
    private var deferred: Set<RecordingID> = []

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
                let discarded = await inbox.keep(holdings.recordings, from: sender)
                await service.withdraw(discarded)
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
        // A new offer may bring what kept the recording from completing.
        deferred.remove(offer.recording)
        switch await inbox.offer(offer, from: sender) {
        case .known(let unfiled):
            await service.arrived(offer.recording, at: unfiled)
            try await channel.send(.received(Received(recording: offer.recording, outcome: .known)), lane: .control)
        case .refused:
            await service.arrived(offer.recording, at: nil)
            try await channel.send(.received(Received(recording: offer.recording, outcome: .refused)), lane: .control)
        case .accepted(let arrival, let held):
            if let arrival { await service.arriving(arrival, from: device) }
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
            if let arrival { await service.arriving(arrival, from: device) }
            if let stored { try await channel.send(.stored(stored), lane: .control) }
        case .verified(let stored, let arrival):
            self.want = nil
            if let arrival { await service.arriving(arrival, from: device) }
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
        while true {
            try await completeWhole()
            switch await inbox.nextWant(from: sender) {
            case .want(let next):
                nextWantID &+= 1
                let want = Want(id: nextWantID, recording: next.recording, path: next.path, from: next.from)
                self.want = want
                try await channel.send(.want(want), lane: .control)
                return
            case .refused(let recording):
                await service.arrived(recording, at: nil)
                try await channel.send(.received(Received(recording: recording, outcome: .refused)), lane: .control)
            case .checked:
                continue
            case .nothing:
                return
            }
        }
    }

    /// Moves every complete recording into `Recordings/`, has the service file it, then says
    /// `received` for it. Filing comes first: a session that ends before `received` goes must not
    /// leave a package in `Recordings/` that nothing files (the phone offers it again, and the Mac
    /// answers `known`). One that could not be completed stays staged until the next session.
    private mutating func completeWhole() async throws {
        while let recording = await inbox.completeRecording(of: sender, skipping: deferred) {
            let outcome: Received.Outcome
            var kept: URL?
            switch await inbox.complete(recording, of: sender) {
            case .kept(let url):
                outcome = .kept
                kept = url
            case .known(let unfiled):
                outcome = .known
                kept = unfiled
            case .refused:
                outcome = .refused
            case .failed:
                deferred.insert(recording)
                continue
            }
            await service.arrived(recording, at: kept)
            try await channel.send(.received(Received(recording: recording, outcome: outcome)), lane: .control)
        }
    }
}
