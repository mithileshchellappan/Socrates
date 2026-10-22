import AVFAudio
import Foundation
import Synchronization

/// Mono audio as it came from the input (input sample rate), with its capture time.
///
/// The input tap copies each `AVAudioPCMBuffer` into a chunk right away; chunks are `Sendable`
/// values, so the writer, the level meter and live captions can consume them on their own
/// tasks without sharing non-Sendable buffers across threads.
public struct AudioChunk: Sendable {
    /// Mono Float32 samples in -1…1.
    public var samples: [Float]
    public var sampleRate: Double
    /// `mach_absolute_time()` of the first frame, when the input provided a valid one.
    public var hostTime: UInt64?
    /// Engine run this chunk came from. A different run than the previous chunk means the input
    /// was reconfigured in between (a discontinuity on the recording clock).
    public var run: Int
    public var peak: Float
    public var rms: Float
    /// Set on a marker without audio (`barrier(_:run:sampleRate:)`): the capture sends one after
    /// its input stopped, and once its writer reaches it every chunk before it is on disk.
    /// Other subscribers see an empty chunk (level 0).
    var barrier: Int?

    /// A marker without audio from engine run `run` (so nothing reads it as a new run).
    static func barrier(_ id: Int, run: Int, sampleRate: Double) -> AudioChunk {
        var chunk = AudioChunk(samples: [], sampleRate: sampleRate, hostTime: nil, run: run)
        chunk.barrier = id
        return chunk
    }

    public init(samples: [Float], sampleRate: Double, hostTime: UInt64?, run: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.hostTime = hostTime
        self.run = run
        var peak: Float = 0
        var sumOfSquares: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
            sumOfSquares += sample * sample
        }
        self.peak = peak
        self.rms = samples.isEmpty ? 0 : (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Copies `buffer`, averaging its channels down to mono. Nil for empty or unsupported buffers.
    public init?(buffer: AVAudioPCMBuffer, time: AVAudioTime?, run: Int) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)

        if let data = buffer.floatChannelData {
            mono.withUnsafeMutableBufferPointer { out in
                for channel in 0..<(interleaved ? 1 : channels) {
                    let source = data[channel]
                    if interleaved {
                        for frame in 0..<frames {
                            var sum: Float = 0
                            for c in 0..<channels { sum += source[frame * channels + c] }
                            out[frame] = sum * scale
                        }
                    } else {
                        for frame in 0..<frames { out[frame] += source[frame] * scale }
                    }
                }
            }
        } else if let data = buffer.int16ChannelData {
            let normalize = scale / Float(Int16.max)
            mono.withUnsafeMutableBufferPointer { out in
                for channel in 0..<(interleaved ? 1 : channels) {
                    let source = data[channel]
                    if interleaved {
                        for frame in 0..<frames {
                            var sum: Float = 0
                            for c in 0..<channels { sum += Float(source[frame * channels + c]) }
                            out[frame] = sum * normalize
                        }
                    } else {
                        for frame in 0..<frames { out[frame] += Float(source[frame]) * normalize }
                    }
                }
            }
        } else {
            return nil
        }
        let hostTime = time.flatMap { $0.isHostTimeValid ? $0.hostTime : nil }
        self.init(samples: mono, sampleRate: buffer.format.sampleRate, hostTime: hostTime, run: run)
    }

    public var frameCount: Int { samples.count }

    /// Level for a meter, 0…1, from RMS on a -60…0 dBFS scale.
    public var meterLevel: Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 60) / 60))
    }

    /// Copies the samples into a new mono Float32 buffer.
    func makeBuffer() -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let destination = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Fans audio chunks out to any number of subscribers (writer, meter, captions).
/// Thread-safe: the input tap sends from the audio thread.
public final class AudioBroadcaster: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<AudioChunk>.Continuation]>([:])
    private let finished = Mutex(false)

    public init() {}

    /// A new stream of every chunk sent from now on.
    public func subscribe(
        bufferingPolicy: AsyncStream<AudioChunk>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: bufferingPolicy)
        if finished.withLock({ $0 }) {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ chunk: AudioChunk) {
        let continuations = subscribers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(chunk)
        }
    }

    /// Ends every stream; later subscribers get a finished stream.
    public func finish() {
        finished.withLock { $0 = true }
        let continuations = subscribers.withLock { subscribers in
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
