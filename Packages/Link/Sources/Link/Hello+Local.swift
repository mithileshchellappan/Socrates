import Foundation
import LinkCore
import RecorderContract

extension Hello {
    /// This build's hello: both features, this build's recorder contract.
    static func local(role: LinkRole, device: LinkDeviceID, instance: UUID) -> Hello {
        Hello(
            role: role,
            device: device,
            instance: instance,
            app: appVersion,
            recorderContract: RecorderContractVersion.current,
            capabilities: [.control, .files]
        )
    }

    /// "1.4 (212)", for the peer's log.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
