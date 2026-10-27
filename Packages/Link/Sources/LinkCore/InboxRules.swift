import Foundation

/// What the Mac takes from an offer: the files of a `.lecture` package and nothing else, with
/// caps. Checked when the offer arrives, before any byte is asked for; the package as a whole is
/// checked again when it is complete.
public enum InboxRules {
    /// The cap of one JSON file (manifest, events, notes).
    public static let maximumJSONBytes: Int64 = 32 << 20
    /// The cap of one audio segment (a full 300 s segment is about 28.8 MB).
    public static let maximumSegmentBytes: Int64 = 64 << 20
    /// The most files one recording may offer.
    public static let maximumFiles = 1000

    /// The package's JSON files.
    public static let jsonFiles: Set<String> = ["manifest.json", "events.json", "notes.json"]

    /// Whether `file` is a package file within its cap: `manifest.json`, `events.json`,
    /// `notes.json` or `audio/seg-NNNN.<ext>`, a size within the cap and a SHA-256 in lowercase
    /// hex. Nothing else: no other folder, no `.` or `..`, no NUL.
    public static func accepts(_ file: OfferedFile) -> Bool {
        guard file.size >= 0, isHash(file.sha256), !file.path.contains("\0") else { return false }
        if jsonFiles.contains(file.path) { return file.size <= maximumJSONBytes }
        guard segmentSequence(file.path) != nil else { return false }
        return file.size <= maximumSegmentBytes
    }

    /// The sequence of `audio/seg-0001.caf` (1), or nil when `path` is not a segment's path: the
    /// `audio/` folder, `seg-`, at least four digits from 1 on, and an extension of one to eight
    /// letters or digits.
    public static func segmentSequence(_ path: String) -> Int? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "audio" else { return nil }
        let name = components[1]
        guard name.hasPrefix("seg-"), let dot = name.lastIndex(of: ".") else { return nil }
        let digits = name[name.index(name.startIndex, offsetBy: 4)..<dot]
        let fileExtension = name[name.index(after: dot)...]
        guard digits.count >= 4, digits.count <= 9, digits.allSatisfy(\.isASCIIDigit),
              (1...8).contains(fileExtension.count), fileExtension.allSatisfy(\.isASCIIAlphanumeric),
              let sequence = Int(digits), sequence >= 1
        else { return nil }
        return sequence
    }

    private static func isHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
    fileprivate var isASCIIAlphanumeric: Bool { isASCII && (isLetter || isNumber) }
}
