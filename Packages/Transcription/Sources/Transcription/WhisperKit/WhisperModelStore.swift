import Foundation
import StudyCore
@preconcurrency import WhisperKit

/// A Core ML Whisper model in Argmax's `whisperkit-coreml` repository.
public struct WhisperModel: Hashable, Sendable, Codable {
    /// Folder name in the repository, e.g. "openai_whisper-large-v3-v20240930".
    public var name: String
    public var repository: String

    public init(name: String, repository: String = "argmaxinc/whisperkit-coreml") {
        self.name = name
        self.repository = repository
    }

    /// large-v3-turbo (≈1.6 GB). Default on Apple silicon Macs.
    public static let largeV3Turbo = WhisperModel(name: "openai_whisper-large-v3-v20240930")
    /// large-v3-turbo compressed to ≈630 MB, for A16+/M-series iPhones and iPads.
    public static let largeV3Turbo626MB = WhisperModel(name: "openai_whisper-large-v3-v20240930_626MB")

    /// The model for this platform: full large-v3-turbo on the Mac, the compressed build elsewhere.
    public static var recommended: WhisperModel {
        #if os(macOS)
        .largeV3Turbo
        #else
        .largeV3Turbo626MB
        #endif
    }
}

/// Where Whisper models live on disk and how they get there.
///
/// Models are always stored under `…/Application Support/StudyPortal/Models` (WhisperKit's
/// default, `~/Documents/huggingface`, syncs to iCloud on the Mac and is backed up on iOS). The
/// folder is excluded from backups. Layout (Hugging Face hub cache):
///
///     Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930/*.mlmodelc
///     Models/models/openai/whisper-large-v3/tokenizer.json
public struct WhisperModelStore: Hashable, Sendable {
    /// The `downloadBase` handed to WhisperKit.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/StudyPortal/Models` (iOS: the app container's equivalent).
    ///
    /// Deliberately ignores `STUDYPORTAL_DATA_ROOT`: models are a shared, re-downloadable cache,
    /// not library data, so throwaway libraries reuse the one 1.6 GB copy.
    public static func shared(fileManager: FileManager = .default) throws -> WhisperModelStore {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let paths = AppPaths(root: support.appending(path: AppPaths.folderName, directoryHint: .isDirectory))
        return WhisperModelStore(directory: paths.models)
    }

    /// Folder WhisperKit loads the model from once downloaded.
    public func folder(for model: WhisperModel) -> URL {
        directory
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: model.repository, directoryHint: .isDirectory)
            .appending(path: model.name, directoryHint: .isDirectory)
    }

    static let requiredComponents = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
    /// Files a compiled component needs to load.
    static let requiredComponentFiles = ["coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
    static let requiredModelFiles = ["config.json", "generation_config.json"]
    /// Written into the model folder once `WhisperKit.download` returned.
    static let completionMarker = ".download-complete"

    /// True when the model can be loaded without the network.
    ///
    /// The Hub downloader moves files into place one by one and creates each component folder
    /// with its first file, so folders alone do not mean much: a download cut short (quit, crash)
    /// leaves all three. The model counts as downloaded once a completed download wrote its
    /// marker, or (for folders from before markers existed) when every file a component needs is
    /// there: each file only appears once it is complete.
    public func isDownloaded(_ model: WhisperModel, fileManager: FileManager = .default) -> Bool {
        let folder = folder(for: model)
        func exists(_ relativePath: String) -> Bool {
            fileManager.fileExists(atPath: folder.appending(path: relativePath).path(percentEncoded: false))
        }
        let hasComponents = Self.requiredComponents.allSatisfy { component in
            ["mlmodelc", "mlpackage"].contains { exists("\(component).\($0)") }
        }
        guard hasComponents else { return false }
        if exists(Self.completionMarker) { return true }
        return Self.requiredModelFiles.allSatisfy(exists) && Self.requiredComponents.allSatisfy { component in
            Self.requiredComponentFiles.allSatisfy { exists("\(component).mlmodelc/\($0)") }
        }
    }

    /// Forgets that the model finished downloading, so the next `download(_:force:)` fetches
    /// whatever is missing (call when loading a "downloaded" model failed).
    public func invalidate(_ model: WhisperModel, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: folder(for: model).appending(path: Self.completionMarker))
    }

    /// Creates the directory and marks it as excluded from device backups.
    public func createDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Downloads the model unless it is already complete on disk (`force` skips that check; the
    /// downloader then only fetches files that are missing or changed). Returns the model folder.
    /// `progress` receives 0…1.
    @discardableResult
    public func download(
        _ model: WhisperModel,
        force: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if !force, isDownloaded(model) {
            progress(1)
            return folder(for: model)
        }
        try createDirectory()
        Log.transcription.info("Downloading Whisper model \(model.name, privacy: .public)")
        let folder: URL
        do {
            folder = try await WhisperKit.download(
                variant: model.name,
                downloadBase: directory,
                from: model.repository,
                progressCallback: { progress($0.fractionCompleted) }
            )
        } catch {
            throw TranscriptionError.modelUnavailable(String(describing: error))
        }
        do {
            try Data(model.name.utf8).write(to: folder.appending(path: Self.completionMarker), options: .atomic)
        } catch {
            Log.transcription.error("Could not mark \(model.name, privacy: .public) downloaded: \(error.localizedDescription, privacy: .public)")
        }
        progress(1)
        return folder
    }
}
