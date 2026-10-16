import Observation
import StudyCore

/// App-wide state and the services wired up at launch. Views read it from the environment.
@Observable
final class AppModel {
    /// Nil only if the library could not be opened; `launchError` then says why.
    let services: StudyServices?
    let launchError: String?

    init(services: StudyServices?, launchError: String? = nil) {
        self.services = services
        self.launchError = launchError
    }

    static func launch() -> AppModel {
        do {
            return AppModel(services: try StudyServices.live())
        } catch {
            Log.app.fault("Could not open the library: \(error.localizedDescription, privacy: .public)")
            return AppModel(services: nil, launchError: error.localizedDescription)
        }
    }

    // MARK: - Anthropic API key

    var hasAPIKey: Bool {
        services?.secrets.hasSecret(for: .anthropicAPIKey) ?? false
    }

    func storeAPIKey(_ key: String) throws {
        try services?.secrets.setSecret(key, for: .anthropicAPIKey)
    }

    func removeAPIKey() throws {
        try services?.secrets.removeSecret(for: .anthropicAPIKey)
    }
}
