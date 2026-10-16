import AVFAudio
import Foundation

/// The format of a recording's files. Fixed for a whole recording so the recording clock has
/// one sample rate even when the input device (and its native rate) changes mid-lecture.
///
/// Files are 16-bit LPCM in CAF: a CAF being written is readable up to its last full packet,
/// so a crash loses at most the audio not yet flushed, never a whole segment.
public struct RecordingFormat: Codable, Sendable, Hashable {
    public var sampleRate: Double
    public var bitDepth: Int
    /// Container file extension.
    public var fileExtension: String

    public init(sampleRate: Double = 48_000, bitDepth: Int = 16, fileExtension: String = "caf") {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileExtension = fileExtension
    }

    /// 48 kHz mono 16-bit CAF.
    public static let standard = RecordingFormat()

    /// Recordings are mono.
    public var channelCount: Int { 1 }

    /// Settings for `AVAudioFile(forWriting:settings:…)`.
    var fileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Float32 mono at `sampleRate`: what the writer hands to `AVAudioFile`.
    var processingFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )
    }

    /// Frames in `duration` at this format's rate.
    public func frames(in duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        let total = Double(seconds) + Double(attoseconds) / 1e18
        return Int64((total * sampleRate).rounded())
    }
}
