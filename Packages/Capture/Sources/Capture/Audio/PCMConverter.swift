import AVFAudio
import Foundation
import Synchronization

/// Converts mono Float32 audio at one sample rate into another PCM format (rate, sample type),
/// keeping filter state across calls so consecutive chunks join without clicks.
///
/// Not thread-safe; owned by one task or actor.
final class PCMConverter {
    let sourceFormat: AVAudioFormat
    let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(sourceSampleRate: Double, targetFormat: AVAudioFormat) {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: source, to: targetFormat)
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        self.sourceFormat = source
        self.targetFormat = targetFormat
        self.converter = converter
    }

    var sourceSampleRate: Double { sourceFormat.sampleRate }

    /// Converts `samples`; with `endOfStream` also drains the converter's tail.
    func convert(_ samples: [Float], endOfStream: Bool = false) -> [AVAudioPCMBuffer] {
        let feed = InputFeed(samples: samples, format: sourceFormat, endOfStream: endOfStream)
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        var output: [AVAudioPCMBuffer] = []
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { count, inputStatus in
                feed.next(count, inputStatus)
            }
            if buffer.frameLength > 0 { output.append(buffer) }
            if let error {
                CaptureLog.capture.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            if status != .haveData { break }
        }
        return output
    }

    /// Converts into mono Float32 samples (target format must be mono Float32).
    func convertToSamples(_ samples: [Float], endOfStream: Bool = false) -> [Float] {
        var result: [Float] = []
        for buffer in convert(samples, endOfStream: endOfStream) {
            guard let data = buffer.floatChannelData?[0] else { continue }
            result.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        return result
    }
}

/// Hands one chunk of samples to `AVAudioConverter`'s (Sendable) input block exactly once.
private final class InputFeed: Sendable {
    let samples: [Float]
    let format: AVAudioFormat
    let endOfStream: Bool
    private let consumed = Mutex(false)

    init(samples: [Float], format: AVAudioFormat, endOfStream: Bool) {
        self.samples = samples
        self.format = format
        self.endOfStream = endOfStream
    }

    func next(
        _ count: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        let isFirst = consumed.withLock { consumed in
            defer { consumed = true }
            return !consumed
        }
        guard isFirst, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else {
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: source.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        status.pointee = .haveData
        return buffer
    }
}
